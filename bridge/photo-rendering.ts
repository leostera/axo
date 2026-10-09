import { convertToPng } from "@earendil-works/pi-coding-agent";
import { Container, getImageDimensions, Image, Text, type ImageTheme } from "@earendil-works/pi-tui";
import type { ImageContent } from "@earendil-works/pi-ai";

/** Pi's Kitty renderer needs PNG; keep the original JPEG disk/model input intact. */
export function renderPhoto(block: ImageContent, theme: ImageTheme, requestRender: () => void): Container {
  const component = new Container();
  const dimensions = getImageDimensions(block.data, block.mimeType);
  if (!dimensions || dimensions.widthPx * dimensions.heightPx > 8_000_000) {
    component.addChild(new Text(theme.fallbackColor("Photo saved locally; use Pi's read tool to inspect it."), 0, 0));
    return component;
  }
  if (block.mimeType === "image/png") {
    component.addChild(new Image(block.data, block.mimeType, theme, { maxWidthCells: 60, maxHeightCells: 20 }));
    return component;
  }
  component.addChild(new Text(theme.fallbackColor("Preparing photo preview…"), 0, 0));
  void convertToPng(block.data, block.mimeType).catch(() => null).then(converted => {
    component.clear();
    if (converted && converted.data.length <= 24 * 1024 * 1024) {
      component.addChild(new Image(converted.data, converted.mimeType, theme, { maxWidthCells: 60, maxHeightCells: 20 }));
    } else {
      component.addChild(new Text(theme.fallbackColor("Photo saved locally; terminal preview unavailable."), 0, 0));
    }
    component.invalidate();
    requestRender();
  });
  return component;
}
