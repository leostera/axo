// Characterization of the pinned public libghostty-vt C API, not a renderer or PTY owner.
// Only synthetic terminal bytes are used. Never print snapshots or formatted content.
#include <assert.h>
#include <ghostty/vt.h>
#include <stdio.h>
#include <string.h>

#define SNAPSHOT_LIMIT (512 * 1024)
#define TEXT_LIMIT 8192

static unsigned char snapshot[SNAPSHOT_LIMIT];

static GhosttyTerminal new_terminal(void) {
    GhosttyTerminal terminal = NULL;
    assert(ghostty_terminal_new(NULL, &terminal, 80, 24) == GHOSTTY_SUCCESS);
    const size_t continuation_limit = 1024;
    assert(ghostty_terminal_set(terminal,
        GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES,
        &continuation_limit) == GHOSTTY_SUCCESS);
    return terminal;
}

static GhosttyFormatter new_formatter(GhosttyTerminal terminal, GhosttyFormatterFormat format) {
    GhosttyFormatter formatter = NULL;
    GhosttyFormatterTerminalOptions options = {
        .size = sizeof(GhosttyFormatterTerminalOptions),
        .emit = format,
        .trim = true,
        .extra = {
            .size = sizeof(GhosttyFormatterTerminalExtra),
            .modes = true,
            .scrolling_region = true,
            .tabstops = true,
            .keyboard = true,
            .screen = {
                .size = sizeof(GhosttyFormatterScreenExtra),
                .cursor = true,
                .style = true,
                .hyperlink = true,
                .protection = true,
                .kitty_keyboard = true,
                .charsets = true,
            },
        },
    };
    assert(ghostty_formatter_terminal_new(NULL, &formatter, terminal, options) == GHOSTTY_SUCCESS);
    return formatter;
}

static size_t formatted(GhosttyTerminal terminal, GhosttyFormatterFormat format,
                        unsigned char *buffer, size_t capacity) {
    GhosttyFormatter formatter = new_formatter(terminal, format);
    size_t required = 0;
    assert(ghostty_formatter_format_buf(formatter, NULL, 0, &required) == GHOSTTY_OUT_OF_SPACE);
    assert(required <= capacity);
    size_t written = 0;
    assert(ghostty_formatter_format_buf(formatter, buffer, capacity, &written) == GHOSTTY_SUCCESS);
    assert(written == required);
    ghostty_formatter_free(formatter);
    return written;
}

static void equal_text(GhosttyTerminal first, GhosttyTerminal second) {
    unsigned char first_text[TEXT_LIMIT], second_text[TEXT_LIMIT];
    size_t first_size = formatted(first, GHOSTTY_FORMATTER_FORMAT_PLAIN, first_text, sizeof first_text);
    size_t second_size = formatted(second, GHOSTTY_FORMATTER_FORMAT_PLAIN, second_text, sizeof second_text);
    assert(first_size == second_size);
    assert(memcmp(first_text, second_text, first_size) == 0);
}

static GhosttyTerminal decode(const unsigned char *bytes, size_t length, GhosttyResult expected) {
    GhosttySnapshotDecoder decoder = NULL;
    GhosttyTerminal restored = NULL;
    assert(ghostty_snapshot_decoder_new_buf(NULL, &decoder, bytes, length) == GHOSTTY_SUCCESS);
    const size_t continuation_limit = 1024;
    assert(ghostty_snapshot_decoder_set(decoder,
        GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES,
        &continuation_limit) == GHOSTTY_SUCCESS);
    assert(ghostty_snapshot_decoder_decode(decoder, &restored) == expected);
    if (expected != GHOSTTY_SUCCESS) assert(restored == NULL);
    ghostty_snapshot_decoder_free(decoder);
    return restored;
}

static void round_trip_continuation(const unsigned char *prefix, size_t prefix_size,
                                   const unsigned char *suffix, size_t suffix_size) {
    GhosttyTerminal source = new_terminal();
    ghostty_terminal_vt_write(source, prefix, prefix_size);
    size_t required = 0;
    assert(ghostty_snapshot_encode_buf(source, NULL, 0, &required) == GHOSTTY_OUT_OF_SPACE);
    assert(required > 20 && required <= sizeof snapshot);
    unsigned char short_buffer[16];
    size_t short_required = 0;
    assert(ghostty_snapshot_encode_buf(source, short_buffer, sizeof short_buffer,
        &short_required) == GHOSTTY_OUT_OF_SPACE);
    assert(short_required == required);
    size_t written = 0;
    assert(ghostty_snapshot_encode_buf(source, snapshot, sizeof snapshot, &written) == GHOSTTY_SUCCESS);
    assert(written == required);

    GhosttyTerminal restored = decode(snapshot, written, GHOSTTY_SUCCESS);
    equal_text(source, restored);
    ghostty_terminal_vt_write(source, suffix, suffix_size);
    ghostty_terminal_vt_write(restored, suffix, suffix_size);
    equal_text(source, restored);

    // Public styled VT formatting can feed a stream-based renderer, but it is
    // not equivalent to installing a complete binary snapshot into GhosttyKit.
    unsigned char replay[TEXT_LIMIT];
    size_t replay_size = formatted(restored, GHOSTTY_FORMATTER_FORMAT_VT, replay, sizeof replay);
    GhosttyTerminal replayed = new_terminal();
    ghostty_terminal_vt_write(replayed, replay, replay_size);
    equal_text(restored, replayed);
    ghostty_terminal_free(replayed);
    // In the alternate-screen case, the binary snapshot must also retain the
    // hidden primary screen. Styled replay above does not establish that.
    static const unsigned char primary_screen[] = "\033[?1049l";
    ghostty_terminal_vt_write(source, primary_screen, sizeof primary_screen - 1);
    ghostty_terminal_vt_write(restored, primary_screen, sizeof primary_screen - 1);
    equal_text(source, restored);

    const size_t truncated_sizes[] = {0, 9, written - 1};
    for (size_t index = 0; index < sizeof truncated_sizes / sizeof truncated_sizes[0]; index++) {
        assert(decode(snapshot, truncated_sizes[index], GHOSTTY_INVALID_VALUE) == NULL);
    }
    snapshot[20] ^= 1; // Corrupt a checksummed payload; no partial terminal is accepted.
    assert(decode(snapshot, written, GHOSTTY_INVALID_VALUE) == NULL);
    ghostty_terminal_free(restored);
    ghostty_terminal_free(source);
}

int main(void) {
    static const unsigned char escape_prefix[] = "saved\r\n\033[31";
    static const unsigned char escape_suffix[] = "mred\033[0m";
    static const unsigned char unicode_prefix[] = "saved\r\n\xe2\x82";
    static const unsigned char unicode_suffix[] = "\xac";
    static const unsigned char alternate_prefix[] = "primary\033[?1049halt\033[2;4H\033[32";
    static const unsigned char alternate_suffix[] = "mgreen\033[0m";
    round_trip_continuation(escape_prefix, sizeof escape_prefix - 1, escape_suffix, sizeof escape_suffix - 1);
    round_trip_continuation(unicode_prefix, sizeof unicode_prefix - 1, unicode_suffix, sizeof unicode_suffix - 1);
    round_trip_continuation(alternate_prefix, sizeof alternate_prefix - 1, alternate_suffix, sizeof alternate_suffix - 1);
    puts("PASS: pinned VT snapshot continuation, UTF-8, alternate screen, bounded output, CRC/truncation; text replay only");
    return 0;
}
