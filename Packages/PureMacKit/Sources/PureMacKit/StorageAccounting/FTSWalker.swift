import Darwin
import Foundation

/// A thin, safe wrapper over `fts(3)` used by every traversal in PureMac.
///
/// Options are fixed to physical traversal: symbolic links are reported, never followed
/// (`FTS_PHYSICAL`); mount points are not crossed (`FTS_XDEV`); the process working directory is
/// never changed (`FTS_NOCHDIR`). Cycles are reported by fts as `FTS_DC`.
struct FTSWalker {
    enum Visit {
        /// A directory in pre-order (before its children).
        case directoryPre
        /// A directory in post-order (after its children).
        case directoryPost
        case file
        case symlink
        /// A directory that could not be read (`FTS_DNR`); this replaces `directoryPost`.
        case unreadableDirectory(errno: Int32)
        /// A directory cycle (`FTS_DC`); not descended.
        case cycle
        /// Metadata could not be obtained (`FTS_NS`/`FTS_ERR`).
        case error(errno: Int32)
        case other
    }

    enum Decision {
        case proceed
        /// Do not descend into this directory (valid for `.directoryPre`).
        case skipChildren
        case stop
    }

    struct Entry {
        let pointer: UnsafeMutablePointer<FTSENT>
        let visit: Visit

        var path: String { String(cString: pointer.pointee.fts_path) }
        var level: Int { Int(pointer.pointee.fts_level) }
        var stat: FileStat? {
            guard let statp = pointer.pointee.fts_statp else { return nil }
            switch visit {
            case .error, .cycle: return nil
            default: return FileStat(statp.pointee)
            }
        }
    }

    enum WalkError: Error {
        case cannotOpen(errno: Int32)
    }

    /// Walks `root`, calling `visit` for every entry. The closure runs synchronously on the
    /// calling thread; callers are responsible for running this off the main actor.
    static func walk(root: String, _ visit: (Entry) -> Decision) throws {
        let options = FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV
        guard let cRoot = strdup(root) else { throw WalkError.cannotOpen(errno: ENOMEM) }
        defer { free(cRoot) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let fts = argv.withUnsafeMutableBufferPointer({ fts_open($0.baseAddress, options, nil) }) else {
            throw WalkError.cannotOpen(errno: errno)
        }
        defer { fts_close(fts) }

        while let ent = fts_read(fts) {
            let info = Int32(ent.pointee.fts_info)
            let visitKind: Visit
            switch info {
            case FTS_D: visitKind = .directoryPre
            case FTS_DP: visitKind = .directoryPost
            case FTS_F: visitKind = .file
            case FTS_SL, FTS_SLNONE: visitKind = .symlink
            case FTS_DNR: visitKind = .unreadableDirectory(errno: ent.pointee.fts_errno)
            case FTS_DC: visitKind = .cycle
            case FTS_NS, FTS_ERR: visitKind = .error(errno: ent.pointee.fts_errno)
            case FTS_DOT: continue
            default: visitKind = .other
            }
            switch visit(Entry(pointer: ent, visit: visitKind)) {
            case .proceed:
                break
            case .skipChildren:
                fts_set(fts, ent, FTS_SKIP)
            case .stop:
                return
            }
        }
    }
}
