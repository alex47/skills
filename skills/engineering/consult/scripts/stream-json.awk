# Encode a prompt or read a top-level field from a CLI JSON event.
function bad() { failed = 1; exit 1 }
function hex4(    i, n, digit) {
    n = 0
    for (i = 0; i < 4; i++) {
        digit = index("0123456789abcdef", tolower(substr(text, pos++, 1))) - 1
        if (digit < 0) bad()
        n = n * 16 + digit
    }
    return n
}
function utf8(n) {
    if (n < 128) return sprintf("%c", n)
    if (n < 2048) return sprintf("%c%c", 192 + int(n / 64), 128 + n % 64)
    if (n < 65536) return sprintf("%c%c%c", 224 + int(n / 4096), 128 + int(n / 64) % 64, 128 + n % 64)
    return sprintf("%c%c%c%c", 240 + int(n / 262144), 128 + int(n / 4096) % 64, 128 + int(n / 64) % 64, 128 + n % 64)
}
function string(keep,    out, c, n, low) {
    if (substr(text, pos++, 1) != "\"") bad()
    out = ""
    while (pos <= length(text)) {
        c = substr(text, pos++, 1)
        if (c == "\"") return out
        if (c == "\\") {
            c = substr(text, pos++, 1)
            if (c == "u") {
                n = hex4()
                if (n >= 55296 && n <= 56319) {
                    if (substr(text, pos, 2) != "\\u") bad()
                    pos += 2; low = hex4()
                    if (low < 56320 || low > 57343) bad()
                    n = 65536 + (n - 55296) * 1024 + low - 56320
                } else if (n >= 56320 && n <= 57343) bad()
                c = utf8(n)
            } else if (c == "n") c = "\n"
            else if (c == "r") c = "\r"
            else if (c == "t") c = "\t"
            else if (c == "b") c = sprintf("%c", 8)
            else if (c == "f") c = sprintf("%c", 12)
            else if (c != "\\" && c != "\"" && c != "/") bad()
        }
        if (keep) out = out c
    }
    bad()
}
function space() { while (substr(text, pos, 1) ~ /[ \t\r\n]/ && pos <= length(text)) pos++ }
function value(keep,    c, out, end) {
    space(); c = substr(text, pos, 1)
    if (c == "\"") return string(keep)
    if (c == "{" || c == "[") {
        end = c == "{" ? "}" : "]"; pos++; space()
        while (substr(text, pos, 1) != end) {
            if (c == "{") { string(0); space(); if (substr(text, pos++, 1) != ":") bad() }
            value(0); space()
            if (substr(text, pos, 1) == end) break
            if (substr(text, pos++, 1) != ",") bad()
            space()
        }
        pos++; return ""
    }
    if (!match(substr(text, pos), /^(true|false|null|-?[0-9]+([.][0-9]+)?([eE][-+]?[0-9]+)?)/)) bad()
    out = substr(text, pos, RLENGTH); pos += RLENGTH
    return keep ? out : ""
}
BEGIN {
    if (mode == "quote") {
        printf "\""
        for (i = 0; i < 32; i++) controls[sprintf("%c", i)] = sprintf("\\u%04x", i)
    }
}
mode == "quote" {
    for (i = 1; i <= length($0); i++) {
        c = substr($0, i, 1)
        if (c == "\\" || c == "\"") printf "\\%s", c
        else if (c in controls) printf "%s", controls[c]
        else printf "%s", c
    }
    consumed += length($0)
    if (consumed < bytes) { printf "\\n"; consumed++ }
    next
}
{
    text = $0; pos = 1; space()
    if (substr(text, pos++, 1) != "{") bad()
    space()
    while (substr(text, pos, 1) != "}") {
        key = string(1); space()
        if (substr(text, pos++, 1) != ":") bad()
        result = value(key == field)
        if (key == field) { if (found) bad(); answer = result; found = 1 }
        space()
        if (substr(text, pos, 1) == "}") break
        if (substr(text, pos++, 1) != ",") bad()
        space()
    }
    pos++; space()
    if (pos <= length(text)) bad()
}
END {
    if (failed) exit 1
    if (mode == "quote") printf "\""
    else if (found) printf "%s", answer
    else exit 2
}
