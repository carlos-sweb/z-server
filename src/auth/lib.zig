const std = @import("std");

pub const impl = @import("impl.zig");
pub const middleware = @import("middleware.zig");

pub const Authenticator = impl.Authenticator;
pub const AuthContext = impl.AuthContext;
pub const Options = impl.Options;
pub const Environment = impl.Environment;
pub const CreateKeySpec = impl.CreateKeySpec;
pub const CreatedKey = impl.CreatedKey;
pub const KeyInfo = impl.KeyInfo;
pub const AuthError = impl.AuthError;

pub const KEY_LEN = impl.KEY_LEN;
pub const PREFIX_LEN = impl.PREFIX_LEN;
pub const RANDOM_RAW_LEN = impl.RANDOM_RAW_LEN;
pub const RANDOM_B64_LEN = impl.RANDOM_B64_LEN;
pub const PAYLOAD_LEN = impl.PAYLOAD_LEN;
pub const CHECKSUM_LEN = impl.CHECKSUM_LEN;
pub const HASH_HEX_LEN = impl.HASH_HEX_LEN;

pub const encodeBase62_6 = impl.encodeBase62_6;
pub const decodeBase62_6 = impl.decodeBase62_6;
pub const parsePepper = impl.parsePepper;
pub const validateChecksum = impl.validateChecksum;
pub const computeHmacHex = impl.computeHmacHex;
pub const maskKey = impl.maskKey;
pub const secureZero = impl.secureZero;

pub const AuthMiddleware = middleware.AuthMiddleware;
pub const MiddlewareOptions = middleware.MiddlewareOptions;
pub const wrap = middleware.wrap;
pub const extractKey = middleware.extractKey;
