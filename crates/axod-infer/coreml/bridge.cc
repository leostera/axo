#import <CoreML/CoreML.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>
#include "bridge.h"
#include "spec.h"
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <stdexcept>
#include <string_view>

// Compiled assets may be read lazily. Keep them alive until the last native
// model reference is released, rather than unlinking them immediately at load.
@interface AXOCoreMLHandle : NSObject
@property(nonatomic, strong) MLModel *model;
@property(nonatomic, strong) NSURL *directoryURL;
@end
@implementation AXOCoreMLHandle
- (void)dealloc {
    _model = nil;
    if (_directoryURL) [NSFileManager.defaultManager removeItemAtURL:_directoryURL error:nil];
}
@end

namespace {
constexpr NSUInteger kElements = 4096;
constexpr NSUInteger kJSONBytes = 1024 * 1024;
constexpr NSUInteger kSpecBytes = 256 * 1024 * 1024;
constexpr NSUInteger kImageBytes = 8 * 1024 * 1024;
constexpr NSUInteger kImagePixels = 16 * 1024 * 1024;
constexpr NSUInteger kRequestBytes = 24 * 1024 * 1024;
struct ImageBudget { NSUInteger count = 0; NSUInteger bytes = 0; };
template<class T> struct CFScoped {
    T value;
    explicit CFScoped(T value) : value(value) {}
    ~CFScoped() { if (value) CFRelease(value); }
    CFScoped(const CFScoped&) = delete;
    CFScoped& operator=(const CFScoped&) = delete;
};

void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
void check(NSError *error) {
    if (error) throw std::runtime_error(error.localizedDescription.UTF8String ?: "Core ML error");
}
char *copyString(NSString *value) {
    const char *utf8 = value.UTF8String;
    require(utf8 != nullptr, "invalid UTF-8");
    char *result = strdup(utf8);
    require(result != nullptr, "allocation failed");
    return result;
}
void boundJSON(id object, NSUInteger &budget, unsigned depth = 0) {
    require(depth < 64, "JSON nesting exceeds 64");
    auto spend = [&](NSUInteger bytes) {
        require(bytes <= budget, "JSON response exceeds 1 MiB");
        budget -= bytes;
    };
    spend(1);
    if ([object isKindOfClass:NSString.class]) {
        spend([object lengthOfBytesUsingEncoding:NSUTF8StringEncoding]);
    } else if ([object isKindOfClass:NSDictionary.class]) {
        for (id key in object) { boundJSON(key, budget, depth + 1); boundJSON(object[key], budget, depth + 1); }
    } else if ([object isKindOfClass:NSArray.class]) {
        for (id item in object) boundJSON(item, budget, depth + 1);
    }
}
char *encode(id object) {
    NSUInteger budget = kJSONBytes;
    boundJSON(object, budget);
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:&error];
    check(error);
    require(data && data.length <= kJSONBytes, "JSON response exceeds 1 MiB");
    return copyString([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
}
// Every C entrypoint is an exception boundary, including Foundation exceptions.
void *boundary(char **error, const std::function<void *()> &action) noexcept {
    if (error) *error = nullptr;
    @autoreleasepool {
        @try {
            try { return action(); }
            catch (const std::exception &e) { if (error) *error = strdup(e.what()); }
            catch (...) { if (error) *error = strdup("unknown native exception"); }
        } @catch (NSException *exception) {
            if (error) *error = strdup(exception.reason.UTF8String ?: "Objective-C exception");
        }
    }
    return nullptr;
}

void relativePath(NSString *path) {
    require([path isKindOfClass:NSString.class] && path.length > 0 && path.length <= 512 && !path.isAbsolutePath, "invalid relative package path");
    for (NSString *part in path.pathComponents) {
        require(part.length > 0 && ![part isEqual:@"."] && ![part isEqual:@".."], "package path traversal is unsupported");
        for (NSUInteger i = 0; i < part.length; ++i) {
            unichar c = [part characterAtIndex:i];
            require((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                    (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.', "unsupported package path character");
        }
    }
}
NSURL *modelSpecURL(NSURL *source) {
    if ([source.pathExtension isEqualToString:@"mlmodel"]) return source;
    require([source.pathExtension isEqualToString:@"mlpackage"], "expected local .mlmodel or .mlpackage");
    NSURL *manifestURL = [source URLByAppendingPathComponent:@"Manifest.json"];
    NSDictionary *manifestAttributes = [NSFileManager.defaultManager attributesOfItemAtPath:manifestURL.path error:nil];
    require([manifestAttributes[NSFileType] isEqual:NSFileTypeRegular] && [manifestAttributes[NSFileSize] unsignedLongLongValue] <= kJSONBytes, "missing or oversized package manifest");
    NSData *manifest = [NSData dataWithContentsOfURL:manifestURL];
    require(manifest != nil, "cannot read package manifest");
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:manifest options:0 error:&error];
    check(error);
    require([object isKindOfClass:NSDictionary.class], "invalid package manifest");
    id identifier = object[@"rootModelIdentifier"];
    id entries = object[@"itemInfoEntries"];
    require([identifier isKindOfClass:NSString.class] && [entries isKindOfClass:NSDictionary.class], "invalid package root");
    require([entries count] > 0 && [entries count] <= 128, "invalid package entry count");
    // Apple's package reader can consult non-root entries too.
    for (id key in entries) {
        id item = entries[key];
        require([item isKindOfClass:NSDictionary.class], "invalid package item");
        relativePath(item[@"path"]);
    }
    id entry = entries[identifier];
    require([entry isKindOfClass:NSDictionary.class], "invalid package entry");
    id path = entry[@"path"];
    relativePath(path);
    NSURL *dataRoot = [source URLByAppendingPathComponent:@"Data" isDirectory:YES];
    NSURL *model = [[dataRoot URLByAppendingPathComponent:path] URLByResolvingSymlinksInPath];
    NSString *prefix = [[dataRoot URLByResolvingSymlinksInPath].path stringByAppendingString:@"/"];
    require([model.path hasPrefix:prefix] && [model.pathExtension isEqualToString:@"mlmodel"], "package model must remain within Data");
    // Compile the exact object we inspected: JSON duplicate-key interpretation must
    // not differ between Foundation and Apple's package reader. Only the private
    // snapshot is normalized; the immutable verified source remains untouched.
    NSData *canonical = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:&error];
    check(error);
    require(canonical && [canonical writeToURL:manifestURL options:NSDataWritingAtomic error:&error], "cannot normalize private package manifest");
    return model;
}

NSString *dtype(MLMultiArrayDataType type) {
    switch (type) {
        case MLMultiArrayDataTypeFloat32: return @"float32";
        case MLMultiArrayDataTypeInt32: return @"int32";
        case MLMultiArrayDataTypeDouble: return @"float64";
        case MLMultiArrayDataTypeFloat16: return @"float16";
        default: return [NSString stringWithFormat:@"native:%ld", (long)type];
    }
}
id describeFeature(MLFeatureDescription *feature) {
    NSMutableDictionary *result = [@{@"optional": @(feature.optional), @"native_type": @(feature.type)} mutableCopy];
    switch (feature.type) {
        case MLFeatureTypeInt64: result[@"type"] = @"int"; break;
        case MLFeatureTypeDouble: result[@"type"] = @"float"; break;
        case MLFeatureTypeString: result[@"type"] = @"string"; break;
        case MLFeatureTypeMultiArray: {
            auto constraint = feature.multiArrayConstraint;
            result[@"type"] = @"tensor";
            result[@"dtype"] = dtype(constraint.dataType);
            if (constraint.dataType != MLMultiArrayDataTypeFloat32 && constraint.dataType != MLMultiArrayDataTypeInt32)
                result[@"unsupported"] = @"raw prediction tensors currently support float32 and int32";
            result[@"shape"] = constraint.shape;
            auto shape = constraint.shapeConstraint;
            result[@"shape_constraint_type"] = @(shape.type);
            if (shape.type == MLMultiArrayShapeConstraintTypeEnumerated) result[@"enumerated_shapes"] = shape.enumeratedShapes;
            if (shape.type == MLMultiArrayShapeConstraintTypeRange) {
                NSMutableArray *ranges = [NSMutableArray array];
                for (NSValue *range in shape.sizeRangeForDimension) {
                    NSRange r = range.rangeValue;
                    [ranges addObject:@{@"lower": @(r.location), @"length": @(r.length)}];
                }
                result[@"shape_ranges"] = ranges;
            }
            break;
        }
        case MLFeatureTypeDictionary:
            result[@"type"] = @"dictionary";
            result[@"key_type"] = feature.dictionaryConstraint.keyType == MLFeatureTypeString ? @"string" : @"int";
            break;
        case MLFeatureTypeImage:
            result[@"type"] = @"image";
            result[@"width"] = @(feature.imageConstraint.pixelsWide);
            result[@"height"] = @(feature.imageConstraint.pixelsHigh);
            result[@"pixel_format"] = @(feature.imageConstraint.pixelFormatType);
            if (feature.imageConstraint.pixelFormatType != kCVPixelFormatType_32BGRA && feature.imageConstraint.pixelFormatType != kCVPixelFormatType_OneComponent8)
                result[@"unsupported"] = @"only BGRA8 and grayscale8 image inputs are implemented";
            result[@"resize"] = @"scale-fill";
            break;
        default: result[@"type"] = @"unsupported";
    }
    return result;
}
id describeFeatures(NSDictionary<NSString *, MLFeatureDescription *> *features) {
    require(features.count <= 32, "model exceeds 32 input or output feature descriptions");
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    for (NSString *name in features) result[name] = describeFeature(features[name]);
    return result;
}
void consume(NSUInteger count, NSUInteger &remaining) {
    require(count <= remaining, "request exceeds 4096 input or output elements");
    remaining -= count;
}
bool number(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID();
}
double finiteNumber(id value) {
    require(number(value) && std::isfinite([value doubleValue]), "expected finite number");
    return [value doubleValue];
}
int64_t integer(id value) {
    double d = finiteNumber(value);
    // JSON integers can preserve all int64 bits; floating values must be exact.
    const char *type = [value objCType];
    if (strchr("csilq", type[0])) return [value longLongValue];
    if (strchr("CSILQ", type[0])) {
        require([value unsignedLongLongValue] <= INT64_MAX, "integer outside int64 range");
        return [value longLongValue];
    }
    require(d >= -9223372036854775808.0 && d < 9223372036854775808.0 && std::trunc(d) == d, "expected int64 integer");
    return (int64_t)d;
}
MLFeatureValue *imageFeature(id object, MLFeatureDescription *description, ImageBudget &budget) {
    require(description.type == MLFeatureTypeImage, "image supplied for non-image feature");
    id url = object[@"data_url"];
    require([url isKindOfClass:NSString.class] && [url length] <= ((kImageBytes + 2) / 3) * 4 + 64, "missing or oversized image data URL");
    NSString *prefix = nil;
    for (NSString *mime in @[@"image/png", @"image/jpeg", @"image/webp"]) {
        NSString *candidate = [NSString stringWithFormat:@"data:%@;base64,", mime];
        if ([url hasPrefix:candidate]) { prefix = candidate; break; }
    }
    require(prefix != nil, "expected PNG, JPEG or WebP image data URL");
    NSData *bytes = [[NSData alloc] initWithBase64EncodedString:[url substringFromIndex:prefix.length] options:0];
    require(bytes && bytes.length > 0 && bytes.length <= kImageBytes, "invalid or oversized base64 image");
    require(budget.count < 4 && bytes.length <= 2 * kImageBytes - budget.bytes, "images exceed four files or 16 MiB");
    ++budget.count; budget.bytes += bytes.length;
    CFScoped source(CGImageSourceCreateWithData((__bridge CFDataRef)bytes, nullptr));
    require(source.value && CGImageSourceGetCount(source.value) == 1, "invalid or animated image");
    CFStringRef actual = CGImageSourceGetType(source.value);
    bool png = actual && CFEqual(actual, CFSTR("public.png"));
    bool jpeg = actual && CFEqual(actual, CFSTR("public.jpeg"));
    bool webp = actual && (CFEqual(actual, CFSTR("org.webmproject.webp")) || CFEqual(actual, CFSTR("public.webp")));
    require((png && [prefix hasPrefix:@"data:image/png;"]) || (jpeg && [prefix hasPrefix:@"data:image/jpeg;"]) ||
            (webp && [prefix hasPrefix:@"data:image/webp;"]), "image MIME does not match encoded bytes");
    CFScoped properties(CGImageSourceCopyPropertiesAtIndex(source.value, 0, nullptr));
    require(properties.value, "missing image dimensions");
    NSDictionary *props = (__bridge NSDictionary *)properties.value;
    uint64_t width = [props[(__bridge NSString *)kCGImagePropertyPixelWidth] unsignedLongLongValue];
    uint64_t height = [props[(__bridge NSString *)kCGImagePropertyPixelHeight] unsignedLongLongValue];
    require(width > 0 && height > 0 && width <= kImagePixels && height <= kImagePixels / width, "image exceeds 16 megapixels");
    auto constraint = description.imageConstraint;
    const auto targetWidth = constraint.pixelsWide, targetHeight = constraint.pixelsHigh;
    require(targetWidth > 0 && targetHeight > 0 && targetWidth <= kImagePixels && targetHeight <= kImagePixels / targetWidth, "native image dimensions exceed 16 megapixels");
    OSType format = constraint.pixelFormatType;
    bool color = format == kCVPixelFormatType_32BGRA;
    require(color || format == kCVPixelFormatType_OneComponent8, "unsupported native image pixel format");
    NSDictionary *options = @{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                              (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
                              (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(std::max(targetWidth, targetHeight))};
    CFScoped image(CGImageSourceCreateThumbnailAtIndex(source.value, 0, (__bridge CFDictionaryRef)options));
    require(image.value, "cannot decode image");
    CVPixelBufferRef raw = nullptr;
    require(CVPixelBufferCreate(kCFAllocatorDefault, targetWidth, targetHeight, format, nullptr, &raw) == kCVReturnSuccess, "image buffer allocation failed");
    CFScoped buffer(raw);
    require(CVPixelBufferLockBaseAddress(buffer.value, 0) == kCVReturnSuccess, "image buffer lock failed");
    @try {
        CFScoped space(color ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray());
        CGBitmapInfo flags = color ? CGBitmapInfo(kCGBitmapByteOrder32Little) | CGBitmapInfo(kCGImageAlphaPremultipliedFirst) : CGBitmapInfo(kCGImageAlphaNone);
        CFScoped context(CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer.value), targetWidth, targetHeight, 8,
                                              CVPixelBufferGetBytesPerRow(buffer.value), space.value, flags));
        require(context.value, "cannot create image rasterizer");
        CGContextSetInterpolationQuality(context.value, kCGInterpolationHigh);
        CGContextDrawImage(context.value, CGRectMake(0, 0, targetWidth, targetHeight), image.value);
    } @finally { CVPixelBufferUnlockBaseAddress(buffer.value, 0); }
    return [MLFeatureValue featureValueWithPixelBuffer:buffer.value];
}
MLFeatureValue *inputFeature(id object, MLFeatureDescription *description, NSUInteger &remaining, ImageBudget &images) {
    require([object isKindOfClass:NSDictionary.class], "feature must be a tagged object");
    id tag = object[@"type"];
    require([tag isKindOfClass:NSString.class], "missing feature type");
    MLFeatureValue *value = nil;
    if ([tag isEqual:@"tensor"]) {
        require(description.type == MLFeatureTypeMultiArray, "tensor supplied for non-tensor feature");
        id shape = object[@"shape"], data = object[@"data"], type = object[@"dtype"];
        require([shape isKindOfClass:NSArray.class] && [shape count] > 0 && [shape count] <= 16 && [data isKindOfClass:NSArray.class], "invalid tensor shape/data");
        require([type isEqual:@"float32"] || [type isEqual:@"int32"], "tensor dtype must be float32 or int32");
        MLMultiArrayDataType nativeType = [type isEqual:@"float32"] ? MLMultiArrayDataTypeFloat32 : MLMultiArrayDataTypeInt32;
        require(description.multiArrayConstraint.dataType == nativeType, "tensor dtype differs from native model dtype");
        NSUInteger count = 1;
        for (id dimension in shape) {
            int64_t size = integer(dimension);
            require(size > 0 && size <= (int64_t)kElements && count <= kElements / size, "tensor shape exceeds element limit");
            count *= size;
        }
        require(count == [data count], "tensor data length differs from shape");
        consume(count, remaining);
        NSError *error = nil;
        MLMultiArray *array = [[MLMultiArray alloc] initWithShape:shape dataType:nativeType error:&error];
        check(error); require(array != nil, "tensor allocation failed");
        for (NSUInteger i = 0; i < count; ++i) {
            double d = finiteNumber(data[i]);
            if (nativeType == MLMultiArrayDataTypeFloat32) {
                require(std::isfinite((float)d), "tensor value outside float32 range");
                array[i] = @((float)d);
            } else {
                int64_t n = integer(data[i]);
                require(n >= INT32_MIN && n <= INT32_MAX, "tensor value outside int32 range");
                array[i] = @(n);
            }
        }
        value = [MLFeatureValue featureValueWithMultiArray:array];
    } else if ([tag isEqual:@"image"]) {
        consume(1, remaining);
        value = imageFeature(object, description, images);
    } else {
        consume(1, remaining);
        id scalar = object[@"value"];
        if ([tag isEqual:@"string"]) {
            require([scalar isKindOfClass:NSString.class], "expected string value");
            value = [MLFeatureValue featureValueWithString:scalar];
        } else if ([tag isEqual:@"float"]) value = [MLFeatureValue featureValueWithDouble:finiteNumber(scalar)];
        else if ([tag isEqual:@"int"]) value = [MLFeatureValue featureValueWithInt64:integer(scalar)];
        else throw std::runtime_error("unsupported input feature type");
    }
    require([description isAllowedValue:value], "feature type or shape is not allowed by native model");
    return value;
}
id outputFeature(MLFeatureValue *value, NSUInteger &remaining) {
    require(value && !value.undefined, "model returned undefined feature");
    switch (value.type) {
        case MLFeatureTypeInt64: consume(1, remaining); return @{@"type": @"int", @"value": @(value.int64Value)};
        case MLFeatureTypeDouble: {
            consume(1, remaining);
            require(std::isfinite(value.doubleValue), "model returned nonfinite number");
            return @{@"type": @"float", @"value": @(value.doubleValue)};
        }
        case MLFeatureTypeString: consume(1, remaining); return @{@"type": @"string", @"value": value.stringValue};
        case MLFeatureTypeMultiArray: {
            MLMultiArray *array = value.multiArrayValue;
            consume(array.count, remaining);
            require(array.dataType == MLMultiArrayDataTypeFloat32 || array.dataType == MLMultiArrayDataTypeInt32, "unsupported native output tensor dtype");
            NSMutableArray *data = [NSMutableArray arrayWithCapacity:array.count];
            for (NSInteger i = 0; i < array.count; ++i) {
                NSNumber *n = array[i]; finiteNumber(n); [data addObject:n];
            }
            return @{@"type": @"tensor", @"dtype": dtype(array.dataType), @"shape": array.shape, @"data": data};
        }
        case MLFeatureTypeDictionary: {
            NSDictionary *dictionary = value.dictionaryValue;
            consume(dictionary.count, remaining);
            NSMutableDictionary *values = [NSMutableDictionary dictionary];
            for (id key in dictionary) {
                require([key isKindOfClass:NSString.class] || number(key), "unsupported dictionary key");
                NSString *label = [key isKindOfClass:NSString.class] ? key : [key stringValue];
                require(values[label] == nil, "dictionary label collision");
                finiteNumber(dictionary[key]); values[label] = dictionary[key];
            }
            return @{@"type": @"dictionary", @"values": values};
        }
        case MLFeatureTypeImage: throw std::runtime_error("image output features are unsupported");
        default: throw std::runtime_error("unsupported native output feature type");
    }
}
} // namespace

extern "C" char *axo_coreml_probe(char **error) {
    return (char *)boundary(error, [&]() -> void * {
        NSMutableArray *devices = [NSMutableArray array];
        for (id device in MLModel.availableComputeDevices) {
            NSString *kind = [device isKindOfClass:MLCPUComputeDevice.class] ? @"cpu" :
                             [device isKindOfClass:MLGPUComputeDevice.class] ? @"gpu" :
                             [device isKindOfClass:MLNeuralEngineComputeDevice.class] ? @"neural-engine" : @"unknown";
            [devices addObject:@{@"kind": kind, @"nativeClass": NSStringFromClass([device class])}];
        }
        NSBundle *framework = [NSBundle bundleForClass:MLModel.class];
        NSString *version = [framework objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"system";
        return encode(@{@"available": @(devices.count > 0), @"devices": devices, @"compute_policy": @"all",
                        @"version": version, @"os_version": NSProcessInfo.processInfo.operatingSystemVersionString});
    });
}
extern "C" void *axo_coreml_load(const char *path, const char *work_directory, char **error) {
    return boundary(error, [&]() -> void * {
        require(path && work_directory, "missing model path or private work directory");
        NSString *string = [[NSString alloc] initWithUTF8String:path];
        require(string != nil && string.isAbsolutePath, "expected absolute UTF-8 model path");
        NSURL *source = [NSURL fileURLWithPath:string];
        // Compile a private snapshot, never a path the caller can swap after the
        // safety check. Package assets stay colocated with the specification.
        NSString *work = [[NSString alloc] initWithUTF8String:work_directory];
        require(work != nil && work.isAbsolutePath, "expected absolute UTF-8 work directory");
        NSURL *directory = [[NSURL fileURLWithPath:work isDirectory:YES] URLByAppendingPathComponent:NSUUID.UUID.UUIDString isDirectory:YES];
        NSError *nativeError = nil;
        NSFileManager *files = NSFileManager.defaultManager;
        require([files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0700} error:&nativeError], "cannot create model staging directory");
        bool ownsDirectory = false;
        @try {
            NSURL *snapshot = [directory URLByAppendingPathComponent:source.lastPathComponent];
            require([files copyItemAtURL:source toURL:snapshot error:&nativeError], "cannot snapshot model");
            // Reject symlinks: a package must not refer to code/assets outside
            // its private snapshot. Compiled models are deliberately not accepted.
            NSMutableArray *items = [NSMutableArray arrayWithObject:snapshot];
            NSDirectoryEnumerator *enumerator = [files enumeratorAtURL:snapshot includingPropertiesForKeys:nil options:0 errorHandler:nil];
            for (NSURL *item in enumerator) { require(items.count < 256, "too many package entries"); [items addObject:item]; }
            for (NSURL *item in items) {
                NSDictionary *attributes = [files attributesOfItemAtPath:item.path error:&nativeError];
                check(nativeError);
                require(![attributes[NSFileType] isEqual:NSFileTypeSymbolicLink], "model symlinks are unsupported");
            }
            NSURL *specURL = modelSpecURL(snapshot);
            NSDictionary *attributes = [files attributesOfItemAtPath:specURL.path error:&nativeError];
            check(nativeError);
            require([attributes[NSFileSize] unsignedLongLongValue] <= kSpecBytes, "model specification exceeds 256 MiB");
            NSData *spec = [NSData dataWithContentsOfURL:specURL options:0 error:&nativeError];
            check(nativeError); require(spec != nil, "cannot read model specification");
            axo::coreml::Verifier verifier([&](std::string_view name) {
                constexpr std::string_view marker = "@model_path/";
                require(name.substr(0, marker.size()) == marker, "blob references must be relative to the source model");
                const auto relative = name.substr(marker.size());
                require(!relative.empty() && relative.size() <= 512, "invalid blob path length");
                size_t start = 0;
                while (start <= relative.size()) {
                    auto end = relative.find('/', start);
                    auto part = relative.substr(start, end == std::string_view::npos ? relative.size() - start : end - start);
                    require(!part.empty() && part != "." && part != "..", "blob path traversal is unsupported");
                    for (unsigned char byte : part)
                        require((byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') ||
                                (byte >= '0' && byte <= '9') || byte == '_' || byte == '-' || byte == '.', "unsupported blob path character");
                    if (end == std::string_view::npos) break;
                    start = end + 1;
                }
                NSString *filename = [[NSString alloc] initWithBytes:relative.data() length:relative.size() encoding:NSUTF8StringEncoding];
                NSURL *blob = [[specURL URLByDeletingLastPathComponent] URLByAppendingPathComponent:filename];
                NSDictionary *attributes = [files attributesOfItemAtPath:blob.path error:nil];
                require([attributes[NSFileType] isEqual:NSFileTypeRegular], "blob is missing or not a verified local file");
            });
            verifier.model(std::string_view((const char *)spec.bytes, spec.length));
            NSURL *compiled = [MLModel compileModelAtURL:snapshot error:&nativeError];
            check(nativeError); require(compiled != nil, "model compilation failed");
            bool moved = false;
            @try {
                NSURL *retained = [directory URLByAppendingPathComponent:@"compiled.mlmodelc" isDirectory:YES];
                require([files moveItemAtURL:compiled toURL:retained error:&nativeError], "cannot retain compiled model in owned directory");
                moved = true;
                MLModelConfiguration *configuration = [MLModelConfiguration new];
                configuration.computeUnits = MLComputeUnitsAll;
                MLModel *model = [MLModel modelWithContentsOfURL:retained configuration:configuration error:&nativeError];
                check(nativeError); require(model != nil, "model load failed");
                // Validate description bounds before handing ownership to Rust.
                char *description = encode(@{@"inputs": describeFeatures(model.modelDescription.inputDescriptionsByName), @"outputs": describeFeatures(model.modelDescription.outputDescriptionsByName)});
                free(description);
                AXOCoreMLHandle *handle = [AXOCoreMLHandle new];
                handle.model = model;
                handle.directoryURL = directory;
                [files removeItemAtURL:snapshot error:nil];
                ownsDirectory = true;
                return (__bridge_retained void *)handle;
            } @finally { if (!moved) [files removeItemAtURL:compiled error:nil]; }
        } @finally { if (!ownsDirectory) [files removeItemAtURL:directory error:nil]; }
    });
}
extern "C" char *axo_coreml_description(void *handle, char **error) {
    return (char *)boundary(error, [&]() -> void * {
        require(handle, "missing model handle");
        MLModel *model = ((__bridge AXOCoreMLHandle *)handle).model;
        return encode(@{@"inputs": describeFeatures(model.modelDescription.inputDescriptionsByName), @"outputs": describeFeatures(model.modelDescription.outputDescriptionsByName)});
    });
}
extern "C" char *axo_coreml_predict(void *handle, const char *json, size_t length, char **error) {
    return (char *)boundary(error, [&]() -> void * {
        require(handle && json && length <= kRequestBytes, "missing model/input or input JSON exceeds 24 MiB");
        MLModel *model = ((__bridge AXOCoreMLHandle *)handle).model;
        NSError *nativeError = nil;
        id request = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:length] options:0 error:&nativeError];
        check(nativeError); require([request isKindOfClass:NSDictionary.class], "prediction must be an object");
        id input = request[@"features"];
        require([input isKindOfClass:NSDictionary.class], "inputs must be an object keyed by feature name");
        id selected = request[@"outputs"];
        auto outputDescriptions = model.modelDescription.outputDescriptionsByName;
        NSArray *names = outputDescriptions.allKeys;
        if (selected) {
            require([selected isKindOfClass:NSArray.class] && [selected count] > 0 && [selected count] <= 32, "select between one and 32 output features");
            NSMutableSet *unique = [NSMutableSet set];
            for (id name in selected) {
                require([name isKindOfClass:NSString.class] && outputDescriptions[name] != nil, "unknown selected output feature");
                require(![unique containsObject:name], "duplicate selected output feature");
                [unique addObject:name];
            }
            names = selected;
        }
        auto descriptions = model.modelDescription.inputDescriptionsByName;
        require([input count] <= kElements, "too many input features");
        NSUInteger remaining = kElements;
        ImageBudget images;
        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (NSString *name in input) {
            require(descriptions[name] != nil, "unknown input feature name");
            values[name] = inputFeature(input[name], descriptions[name], remaining, images);
        }
        for (NSString *name in descriptions) require(values[name] != nil || descriptions[name].optional, "missing required input feature");
        for (NSString *name in names)
            require(outputDescriptions[name].type != MLFeatureTypeImage, "image output features are unsupported");
        MLDictionaryFeatureProvider *provider = [[MLDictionaryFeatureProvider alloc] initWithDictionary:values error:&nativeError];
        check(nativeError);
        id<MLFeatureProvider> output = [model predictionFromFeatures:provider error:&nativeError];
        check(nativeError); require(output != nil, "prediction returned no output");
        remaining = kElements;
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        for (NSString *name in names) result[name] = outputFeature([output featureValueForName:name], remaining);
        return encode(result);
    });
}
extern "C" void axo_coreml_free(void *handle) {
    boundary(nullptr, [&]() -> void * { if (handle) { id model = CFBridgingRelease(handle); (void)model; } return nullptr; });
}
extern "C" void axo_coreml_string_free(char *string) { free(string); }
