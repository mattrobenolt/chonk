//! x86 register probes and the OS-state gate for vector payloads.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

// Intel SDM: XCR0 bits 1/2 enable SSE/YMM. Bits 5/6/7 enable AVX-512 state.
pub const avx_state: u64 = (1 << 1) | (1 << 2);
pub const avx512_state: u64 = avx_state | (1 << 5) | (1 << 6) | (1 << 7);
const xsave_osxsave: u32 = (1 << 26) | (1 << 27);

pub const CpuidResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

pub const Native = struct {
    pub fn readCpuid(leaf: u32, subleaf: u32) CpuidResult {
        var eax: u32 = undefined;
        var ebx: u32 = undefined;
        var ecx: u32 = undefined;
        var edx: u32 = undefined;
        asm volatile ("cpuid"
            : [eax] "={eax}" (eax),
              [ebx] "={ebx}" (ebx),
              [ecx] "={ecx}" (ecx),
              [edx] "={edx}" (edx),
            : [leaf] "{eax}" (leaf),
              [subleaf] "{ecx}" (subleaf),
        );
        return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
    }

    // Only matchesXcr0 calls this probe, after the XSAVE/OSXSAVE gate.
    fn readXcr0() u64 {
        var low: u32 = undefined;
        var high: u32 = undefined;
        asm volatile ("xgetbv"
            : [low] "={eax}" (low),
              [high] "={edx}" (high),
            : [index] "{ecx}" (@as(u32, 0)),
        );
        return (@as(u64, high) << 32) | low;
    }
};

/// The probe parameter lets tests reject unsafe reads without an x86 host.
pub fn matchesXcr0(comptime Probe: type, mask: u64, expected: u64) bool {
    const features = Probe.readCpuid(1, 0).ecx;
    // XGETBV faults without either hardware support or OS enablement.
    if (features & xsave_osxsave != xsave_osxsave) return false;
    return (Probe.readXcr0() & mask) == expected;
}

fn TestProbe(comptime ecx: u32, comptime xcr0: u64) type {
    return struct {
        fn readCpuid(leaf: u32, subleaf: u32) CpuidResult {
            assert(leaf == 1);
            assert(subleaf == 0);
            return .{ .eax = 0, .ebx = 0, .ecx = ecx, .edx = 0 };
        }

        fn readXcr0() u64 {
            if (ecx & xsave_osxsave != xsave_osxsave) @panic("unsafe XGETBV probe");
            return xcr0;
        }
    };
}

test "XGETBV requires both XSAVE and OSXSAVE" {
    inline for ([_]u32{ 0, 1 << 26, 1 << 27 }) |features| {
        try testing.expect(!matchesXcr0(TestProbe(features, avx512_state), avx_state, avx_state));
    }
}

test "AVX requires both SSE and YMM state" {
    inline for ([_]u64{ 0, 1 << 1, 1 << 2 }) |state| {
        try testing.expect(!matchesXcr0(TestProbe(xsave_osxsave, state), avx_state, avx_state));
    }
    try testing.expect(matchesXcr0(TestProbe(xsave_osxsave, avx_state), avx_state, avx_state));
    try testing.expect(matchesXcr0(TestProbe(xsave_osxsave, avx512_state), avx_state, avx_state));
}

test "AVX-512 requires every extended state component" {
    inline for ([_]u6{ 1, 2, 5, 6, 7 }) |bit| {
        const incomplete = avx512_state & ~(@as(u64, 1) << bit);
        try testing.expect(!matchesXcr0(
            TestProbe(xsave_osxsave, incomplete),
            avx512_state,
            avx512_state,
        ));
    }
    try testing.expect(matchesXcr0(
        TestProbe(xsave_osxsave, avx512_state),
        avx512_state,
        avx512_state,
    ));
    try testing.expect(matchesXcr0(
        TestProbe(xsave_osxsave, avx512_state | (1 << 9)),
        avx512_state,
        avx512_state,
    ));
}
