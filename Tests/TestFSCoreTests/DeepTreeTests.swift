//
//  DeepTreeTests.swift
//
//  TreeBuilder must handle deeply-nested JSON trees without
//  overflowing the run-time stack. The Python jsonfs.py reference
//  is iterative; the Swift port was originally a recursive walk
//  (visit ↔ visitDirectory) and crashed at ~243 frames on the
//  dispatch-queue thread that runs `loadResource` (the queue's
//  per-thread stack is much smaller than the 8 MB main thread).
//  archive_torture_path_lengths.json fixture (196 levels) hits
//  this in production; tests construct the structure
//  programmatically so the regression is exercisable in the SPM
//  target without committing a multi-MB JSON fixture.
//

import Foundation
import XCTest

@testable import TestFSCore

final class DeepTreeTests: XCTestCase {

    private func defaultOptions() -> MountOptions {
        var opts = MountOptions(config: "/tmp/ignored.json")
        opts.addMacosCacheFiles = false
        return opts
    }

    /// Build a chain of `depth` nested directories with a leaf file
    /// at the bottom. Each directory has exactly one child (the next
    /// level), so the total node count is `depth + 1` (depth dirs +
    /// 1 leaf file).
    private func makeChain(depth: Int) -> TreeNode {
        var node: TreeNode = .file(name: "leaf.txt", size: 1)
        for level in (0..<depth).reversed() {
            node = .directory(name: "d\(level)", contents: [node])
        }
        return node
    }

    /// 1000 levels deep on the main thread (8 MB stack). Walks the
    /// chain to confirm every level is reachable, sizes/links match.
    func testThousandLevelDeepTreeBuilds() throws {
        let depth = 1000
        let root = makeChain(depth: depth)
        let index = try TreeBuilder.build(root: root, options: defaultOptions())

        XCTAssertEqual(index.nodesByID.count, depth + 1)

        var current = index.root
        for level in 0..<depth {
            XCTAssertEqual(current.kind, .directory)
            XCTAssertEqual(current.childrenIDs.count, 1)
            guard let next = current.childrenIDs.first.flatMap({ index.node(for: $0) }) else {
                return XCTFail("chain broken at level \(level)")
            }
            current = next
        }
        XCTAssertEqual(current.kind, .file)
        XCTAssertEqual(current.name, "leaf.txt")
        XCTAssertEqual(current.size, 1)
    }

    /// 500-level chain on a 256 KB pthread stack. This is what the
    /// dispatch queue running `loadResource` gives us in production
    /// — much smaller than the main thread's 8 MB. A recursive
    /// `visit` ↔ `visitDirectory` overflows here at ~200 frames,
    /// matching the production crash on
    /// archive_torture_path_lengths.json (196 levels). Iterative
    /// TreeBuilder must run in O(1) stack frames.
    func testDeepTreeBuildsOnSmallStack() throws {
        let depth = 500
        let root = makeChain(depth: depth)
        let index = try buildOnSmallStack(root: root, options: defaultOptions())
        XCTAssertEqual(index.nodesByID.count, depth + 1)
    }

    /// Spawn a 256 KB-stack pthread, run `TreeBuilder.build` on it,
    /// and return the index. Encapsulates the C pthread dance so the
    /// test body stays small.
    private func buildOnSmallStack(
        root: TreeNode, options: MountOptions
    ) throws -> TreeIndex {
        nonisolated(unsafe) var built: TreeIndex?
        nonisolated(unsafe) var failure: String?
        let group = DispatchGroup()
        group.enter()

        var attr = pthread_attr_t()
        XCTAssertEqual(pthread_attr_init(&attr), 0)
        XCTAssertEqual(pthread_attr_setstacksize(&attr, 256 * 1024), 0)

        let context = WorkerContext(root: root, options: options) { result in
            switch result {
            case .success(let idx): built = idx
            case .failure(let msg): failure = msg
            }
            group.leave()
        }
        let opaque = Unmanaged.passRetained(context).toOpaque()
        var tid: pthread_t?
        let createResult = pthread_create(&tid, &attr, Self.runWorker, opaque)
        pthread_attr_destroy(&attr)
        guard createResult == 0 else {
            // pthread_create owns the retain on success; on failure we
            // own it and must release so the harness doesn't leak the
            // context and group.wait() doesn't hang on a worker that
            // never ran.
            Unmanaged<WorkerContext>.fromOpaque(opaque).release()
            group.leave()
            throw WorkerHarnessError.createFailed(createResult)
        }
        group.wait()
        // Reap the joinable thread or its kernel-side resources leak.
        if let tid = tid { pthread_join(tid, nil) }

        if let failure = failure { throw WorkerHarnessError.buildFailed(failure) }
        guard let index = built else { throw WorkerHarnessError.noResult }
        return index
    }

    private enum WorkerHarnessError: Error, CustomStringConvertible {
        case createFailed(Int32)
        case buildFailed(String)
        case noResult
        var description: String {
            switch self {
            case .createFailed(let code): return "pthread_create failed: \(code)"
            case .buildFailed(let msg): return msg
            case .noResult: return "worker thread produced no result"
            }
        }
    }

    /// pthread entry point. Top-level so it stays a non-capturing
    /// `@convention(c)` function pointer; argument is the boxed
    /// WorkerContext passed in via `pthread_create`'s `void *`.
    private static let runWorker: @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer? = { ptr in
        let ctx = Unmanaged<WorkerContext>.fromOpaque(ptr).takeRetainedValue()
        do {
            let idx = try TreeBuilder.build(root: ctx.root, options: ctx.options)
            ctx.complete(.success(idx))
        } catch {
            ctx.complete(.failure("build threw: \(error)"))
        }
        return nil
    }

    /// Empty directory at the root — degenerate case the iterative
    /// loop's exit-phase must handle without spinning.
    func testEmptyRootDirectoryBuilds() throws {
        let root: TreeNode = .directory(name: "r", contents: [])
        let index = try TreeBuilder.build(root: root, options: defaultOptions())
        XCTAssertEqual(index.nodesByID.count, 1)
        XCTAssertEqual(index.root.childrenIDs.count, 0)
        XCTAssertEqual(index.root.kind, .directory)
    }

    /// Single-child directories at multiple depths — exercises the
    /// frame push/pop lifecycle on a shape the matrix doesn't cover.
    func testSingleChildPerLevelBuilds() throws {
        let root: TreeNode = .directory(name: "r", contents: [
            .directory(name: "a", contents: [
                .directory(name: "b", contents: []),
                .file(name: "x.txt", size: 1)
            ])
        ])
        let index = try TreeBuilder.build(root: root, options: defaultOptions())
        XCTAssertEqual(index.nodesByID.count, 4)

        guard let aDir = index.lookup(name: "a", in: index.rootID),
              let bDir = index.lookup(name: "b", in: aDir.id),
              let xFile = index.lookup(name: "x.txt", in: aDir.id)
        else { return XCTFail("expected children missing") }
        XCTAssertEqual(bDir.kind, .directory)
        XCTAssertEqual(xFile.size, 1)
    }

    /// Collision deep in the tree: the iterative loop must run the
    /// shared `appendChild` collision helper at every depth, not just
    /// the root frame. Pairs with TreeBuilderCollisionTests but
    /// confirmed at depth that's deep enough to require the iterative
    /// path even pre-fix on a small stack.
    func testDeepCollisionAtDepth50() throws {
        // 50 levels of single-child dirs, then two same-named files
        // at the leaf — collision must yield 2 childIDs, last-wins.
        var leaf: TreeNode = .directory(name: "deep", contents: [
            .file(name: "dup", size: 1),
            .file(name: "dup", size: 2)
        ])
        for level in (0..<50).reversed() {
            leaf = .directory(name: "d\(level)", contents: [leaf])
        }
        let index = try TreeBuilder.build(root: leaf, options: defaultOptions())

        var cur = index.root
        for _ in 0..<50 {
            guard let next = cur.childrenIDs.first.flatMap({ index.node(for: $0) }) else {
                return XCTFail("chain broken")
            }
            cur = next
        }
        // cur is now the "deep" directory holding the dup pair.
        XCTAssertEqual(cur.name, "deep")
        XCTAssertEqual(cur.childrenIDs.count, 2,
            "deep collision must keep both childIDs")
        XCTAssertEqual(index.lookup(name: "dup", in: cur.id)?.size, 2,
            "deep collision is last-wins on byName")
    }

    // Boxed input/output for the small-stack pthread harness so the
    // C-style entry point can carry it through `void *`.
    private final class WorkerContext {
        let root: TreeNode
        let options: MountOptions
        let onComplete: (ResultBox) -> Void
        init(root: TreeNode, options: MountOptions,
             onComplete: @escaping (ResultBox) -> Void) {
            self.root = root
            self.options = options
            self.onComplete = onComplete
        }
        func complete(_ result: ResultBox) { onComplete(result) }
    }
    private enum ResultBox {
        case success(TreeIndex)
        case failure(String)
    }

    /// Root cache-control dotfiles must come after user content in the
    /// directory listing. With a JSON tree that pre-defines
    /// `.metadata_never_index`, the user's entry is inserted first,
    /// the cache version is inserted last, and lookup last-wins on
    /// the cache one (size 0).
    func testRootCacheFilesAppendedInOrderAfterUserContent() throws {
        var opts = defaultOptions()
        opts.addMacosCacheFiles = true
        let root: TreeNode = .directory(name: "r", contents: [
            .file(name: ".metadata_never_index", size: 99),
            .file(name: "a.txt", size: 1)
        ])
        let index = try TreeBuilder.build(root: root, options: opts)

        // User content first (.metadata_never_index size 99, a.txt size 1),
        // then the 3 cache-control files (sizes 0).
        let kinds = index.root.childrenIDs.compactMap { index.node(for: $0)?.size }
        XCTAssertEqual(kinds, [99, 1, 0, 0, 0],
            "user content first, cache files appended in declared order")
        XCTAssertEqual(index.lookup(name: ".metadata_never_index", in: index.rootID)?.size, 0,
            "byName last-wins lookup hits the appended cache file")
    }
}
