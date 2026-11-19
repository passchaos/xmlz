//! Quote-aware lexical ends shared by element and character-data scanners.
pub fn findDeclarationEnd(input: []const u8, start: usize) ?usize {
    var quote: u8 = 0;
    var internal_subset_depth: usize = 0;
    var i = start;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '"' or c == '\'') {
            quote = c;
            continue;
        }
        if (c == '[') {
            internal_subset_depth += 1;
            continue;
        }
        if (c == ']') {
            if (internal_subset_depth != 0) internal_subset_depth -= 1;
            continue;
        }
        if (c == '>' and internal_subset_depth == 0) return i;
    }
    return null;
}

pub fn findTagEnd(input: []const u8, start: usize) ?usize {
    var quote: u8 = 0;
    var i = start;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (quote != 0) {
            if (c == quote) quote = 0;
        } else if (c == '"' or c == '\'') {
            quote = c;
        } else if (c == '>') {
            return i;
        }
    }
    return null;
}
