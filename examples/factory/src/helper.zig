//! The dependency module: imported by each variant's app module through
//! make_exe, resolved against that variant's target.

pub fn tag() []const u8 {
    return "factory-helper";
}
