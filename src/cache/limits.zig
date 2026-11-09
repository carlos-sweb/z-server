/// Larger values skip cache and serve from SQLite.
/// Kept below request.max_body_size (64 KiB) so a 40 KiB POST can exercise
/// the uncached path over HTTP.
pub const MAX_VALUE_BYTES: usize = 32 * 1024;

pub const CACHE_TTL_SECONDS: u32 = 60;
