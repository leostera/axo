using System.Text.Json;

namespace Axo;

public static class CodexInteraction
{
    public static bool IsConfirmation(JsonElement parameters)
    {
        if (!parameters.TryGetProperty("mode", out var mode) || mode.ValueKind != JsonValueKind.String || mode.GetString() != "form"
            || !parameters.TryGetProperty("requestedSchema", out var schema) || schema.ValueKind != JsonValueKind.Object) return false;
        var allowed = new[] { "type", "properties", "required", "additionalProperties", "title", "description", "$schema" };
        if (schema.EnumerateObject().Any(property => !allowed.Contains(property.Name))) return false;
        return schema.TryGetProperty("type", out var type) && type.ValueKind == JsonValueKind.String && type.GetString() == "object"
            && schema.TryGetProperty("properties", out var fields) && fields.ValueKind == JsonValueKind.Object && !fields.EnumerateObject().Any()
            && (!schema.TryGetProperty("required", out var required) || required.ValueKind == JsonValueKind.Array && required.GetArrayLength() == 0);
    }
    public static string Describe(JsonElement parameters)
    {
        var message = parameters.TryGetProperty("message", out var supplied) ? supplied.GetString() ?? "Permission requested" : "Permission requested";
        if (parameters.TryGetProperty("serverName", out var server)) message += "\nServer: " + server.GetString();
        if (parameters.TryGetProperty("_meta", out var metadata))
        {
            if (metadata.TryGetProperty("tool_params_display", out var details)) message += "\n" + ToolPresentation.Display(details);
            if (metadata.TryGetProperty("persist", out var persist) && persist.ValueKind == JsonValueKind.True)
                message += "\nThis request asks to remember permission.";
        }
        return message;
    }
}
