#![no_main]
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    if let Ok(text) = std::str::from_utf8(data) {
        // rnix::tokenize returns a LAZY iterator; drain it so the lexer actually runs
        // on the input (the unconsumed `let _ = tokenize(..)` form covers ~no code).
        for token in rnix::tokenize(text) {
            std::hint::black_box(token);
        }
    }
});
