import Foundation
import Domain
import Testing

#if os(iOS) || os(macOS)
// linux-blind: URLSession/URLProtocol 传输语义在 macOS CI 真跑（家族 N/O/P 同规）
@testable import Infrastructure

/// SU-M15-MEDCATALOG · binds: SU-M15-MEDCATALOG（TC-M15-12 检查 resolver，委员会测试席）
/// SP-64 检查 resolver 行为钉（tech-spec §5.53 / ui-ux §5.12.4）：
/// tag 页清单（SSR）→ 最高 installable pointer → pinned root 验签 → floor 反回退 →
/// 本地比较；ETag/304、限流、404/410/5xx、取消、单飞、字节上限、逐跳主机门、
/// 重定向与 delegate/ETag 缓存直测。夹具复用 `MedicalCatalogFixture`（同目标）。
///
/// 作用域属主纪律（2026-10-07 通道迁移）：检查面 = cnb.cool 的两个 URL 前缀——
/// `/releases/tag/medical-data`（SSR 清单）与 `/releases/download/medical-data/
/// medical-data-catalog-*`（pointer，常量构造）；同主机的 fetcher 套件独占
/// `…/releases/download/medical-data/medical-data-package-*` 前缀。两套件按
/// **URL 前缀**清表（URLProtocolStub.reset(urlPrefixes:)）——主机会域会互擦
/// （旧 api.cnb.cool 属主随匿名 401 修复退役）。
@Suite("SU-M15-MEDCATALOG · SP-64 检查 resolver 行为钉", .serialized)
struct MedicalCatalogReleaseResolverTests {

    // MARK: - 组装助手

    private static func resetStubs() {
        URLProtocolStub.reset(urlPrefixes: [
            "https://cnb.cool/robinhoo1973/Resources/-/releases/tag/medical-data",
            "https://cnb.cool/robinhoo1973/Resources/-/releases/download/medical-data/medical-data-catalog-",
        ])
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    /// SSR tag 页夹具（2026-10-07 通道迁移）：`releaseDetailStatus=success` +
    /// `release.tagRef` 绑定 + 资产表逐项形状合规（`CNBReleasePageInventoryParser`
    /// 全门通过）。`pathFor` 供越界 path 负例注入。
    private static func tagPageHTML(_ names: [String],
                                    pathFor: (String) -> String = { name in
                                        "/robinhoo1973/Resources/-/releases/download/medical-data/" + name
                                    }) -> Data {
        let assets: [[String: Any]] = names.map { name in
            ["name": name,
             "path": pathFor(name),
             "hashAlgo": "sha256",
             "hashValue": String(repeating: "a", count: 64),
             "sizeInByte": 1024]
        }
        let payload: [String: Any] = ["props": ["pageProps": [
            "releaseDetailStatus": "success",
            "releasesDetailData": ["release": [
                "tagRef": "refs/tags/medical-data",
                "assets": assets]]]]]
        let json = try! JSONSerialization.data(withJSONObject: payload) // try?-ok: 测试夹具 JSON 由字面量字典构造，无失败路径
        return Data(#"<script id="__NEXT_DATA__" type="application/json">"#.utf8) + json
            + Data("</script>".utf8)
    }

    /// pointer 用与 resolver 相同的协议常量构造（单一事实源：地址不采信页面数据）。
    private static func pointerURL(_ assetName: String) -> String {
        MedicalCatalogReleaseProtocol.releaseBaseURL + "/" + assetName
    }

    private static func makeResolver(fixture: MedicalCatalogFixture,
                                     trust: MedicalCatalogTrustStore? = nil,
                                     local: MedicalCatalogInstalledVersion? = nil,
                                     session: URLSession? = nil) -> MedicalCatalogReleaseResolver {
        MedicalCatalogReleaseResolver(pinnedRootJSON: fixture.pinnedRootJSON,
                                      makeVerifier: { root in
                                          CryptoKitMedicalCatalogTrustVerifier(
                                              pinnedRootJSON: root, now: { MedicalCatalogFixture.clock })
                                      },
                                      hasher: CryptoKitContentHasher(),
                                      session: session ?? makeSession(),
                                      trust: trust,
                                      localVersion: { local },
                                      now: { MedicalCatalogFixture.clock })
    }

    /// 发布 tag 页 + installable-30 pointer 的标准路由（逐键写入——整字典赋值
    /// 会跨套件清表，违反 URLProtocolStub 作用域纪律）。
    private static func installRoutes(_ fixture: MedicalCatalogFixture,
                                      pointerBody: Data? = nil) -> [(URL, URLProtocolStub.Script)] {
        [
            (MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(
                body: tagPageHTML([fixture.pointerAssetName]))),
            (URL(string: pointerURL(fixture.pointerAssetName))!, URLProtocolStub.Script(
                body: pointerBody ?? fixture.signedPointerJSON)),
        ]
    }

    private static func apply(_ routes: [(URL, URLProtocolStub.Script)]) {
        for (url, script) in routes {
            URLProtocolStub.setScript(script, for: url)
        }
    }

    private static func apply(_ route: (URL, URLProtocolStub.Script)) {
        apply([route])
    }

    /// 有界轮询等待目标 URL 被请求（替代固定 sleep 的确定性时序，评审修复：
    /// 150ms 固定窗口在 CI 高负载下会 flake）。
    private func waitForRequest(_ url: URL, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if URLProtocolStub.requestLog.contains(where: { $0.url == url }) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("请求未在 \(timeout)s 内到达：\(url)")
        throw StubDeadlineTimeout()
    }

    private func inventoryHits() -> Int {
        URLProtocolStub.requestLog.filter { $0.url == MedicalCatalogReleaseResolver.tagPageURL }.count
    }

    // MARK: - 候选选择与状态归约

    @Test("happy path：inventory + 验签 pointer → updateAvailable 携带完整候选")
    func checkFindsInstallableUpdate() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply(Self.installRoutes(fixture))
        let resolver = Self.makeResolver(fixture: fixture)
        let outcome = try await resolver.check()
        guard case .updateAvailable(let candidate) = outcome.state else {
            Issue.record("预期 updateAvailable，实际 \(outcome.state)")
            return
        }
        #expect(candidate.catalogVersion == 30)
        #expect(candidate.dataVersion == fixture.signedExpectation.dataVersion)
        #expect(candidate.schemaVersion == 7)   // CNB v7-only 契约（2026-10-03 迁移）
        let expected = try fixture.candidate()
        #expect(outcome.candidate == expected)
    }

    @Test("resolver rejects a physical v6 pointer under the v7-only contract")
    func checkRejectsPhysicalV6Update() async throws {
        // CNB 单写者 v7-only（2026-10-03）：v6 指针按 invalidField 拒绝，
        // 解析器归 verificationFailed——旧「接受 v6」契约已废止。
        // `make(schemaVersion: 6)` 在 expectation 门即抛（acceptance 套件钉住该
        // 形态）——改以 v7 夹具 + catalog 私钥重签 sqliteSchemaVersion=6 的指针体。
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        let v6Pointer = try fixture.signedPointer { $0["sqliteSchemaVersion"] = 6 }
        Self.resetStubs()
        Self.apply(Self.installRoutes(fixture, pointerBody: v6Pointer))
        let resolver = Self.makeResolver(fixture: fixture)
        let outcome = try await resolver.check()
        #expect(outcome.state == .verificationFailed, "v6 pointer must be rejected, actual=\(outcome.state)")
    }

    @Test("本地 (schemaVersion,dataVersion) 一致 → upToDate，不重复下载")
    func checkReportsUpToDateWhenLocalDataMatches() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply(Self.installRoutes(fixture))
        let local = MedicalCatalogInstalledVersion(schemaVersion: 7,   // CNB v7-only 契约
                                                   dataVersion: fixture.signedExpectation.dataVersion)
        let resolver = Self.makeResolver(fixture: fixture, local: local)
        let outcome = try await resolver.check()
        guard outcome.state == .upToDate, outcome.candidate == nil else {
            Issue.record("本地数据一致应呈 upToDate 且无候选，实际 \(outcome.state) / candidate=\(String(describing: outcome.candidate))")
            return
        }
    }

    @Test("physical v6 pointer is rejected under the v7-only contract")
    func checkRejectsUpToDateForPhysicalV6() async throws {
        // 同 checkRejectsPhysicalV6Update：v7 夹具 + 重签 v6 指针体；本地版本号
        // 即便自称 v6 也不影响解码门拒绝（拒绝先于本地比较）。
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        let v6Pointer = try fixture.signedPointer { $0["sqliteSchemaVersion"] = 6 }
        Self.resetStubs()
        Self.apply(Self.installRoutes(fixture, pointerBody: v6Pointer))
        let local = MedicalCatalogInstalledVersion(schemaVersion: 6, dataVersion: fixture.signedExpectation.dataVersion)
        let resolver = Self.makeResolver(fixture: fixture, local: local)
        let outcome = try await resolver.check()
        #expect(outcome.state == .verificationFailed, "v6 pointer must be rejected, actual=\(outcome.state)")
    }

    @Test("Release 只有 progress pointer → noInstallableAvailable，不误报最新/更新")
    func checkReportsNoInstallableWhenOnlyProgress() async throws {
        let fixture = try MedicalCatalogFixture.make(installable: false)
        defer { fixture.cleanUp() }
        let progressName = MedicalCatalogReleaseProtocol.pointerAssetName(installable: false, catalogVersion: 30,
                                                                             issuedAt: fixture.signedExpectation.issuedAt)
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(
            body: Self.tagPageHTML([progressName]))))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .noInstallableAvailable)
    }

    @Test("高序号 progress 不遮蔽低序号 installable——候选只看 installable")
    func checkPicksHighestInstallableIgnoringProgress() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        // 伪造的 progress-40 只需占名——解析器永不下载它
        let progressName = MedicalCatalogReleaseProtocol.pointerAssetName(installable: false, catalogVersion: 40,
                                                                             issuedAt: fixture.signedExpectation.issuedAt)
        Self.resetStubs()
        Self.apply([
            (MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(
                body: Self.tagPageHTML([progressName, fixture.pointerAssetName]))),
            (URL(string: Self.pointerURL(fixture.pointerAssetName))!, URLProtocolStub.Script(body: fixture.signedPointerJSON)),
        ])
        let resolver = Self.makeResolver(fixture: fixture)
        let outcome = try await resolver.check()
        guard case .updateAvailable(let candidate) = outcome.state else {
            Issue.record("预期 updateAvailable，实际 \(outcome.state)")
            return
        }
        #expect(candidate.catalogVersion == 30)
    }

    @Test("清单里非 pointer 文法的名字（README/包文法等）不进入候选")
    func checkIgnoresNonPointerNames() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(
            body: Self.tagPageHTML([
                "README.md",
                "medical-data-package-sqlite-" + String(repeating: "b", count: 64)
                    + "-cipher-" + String(repeating: "c", count: 64) + ".bin",
                "medical-data-catalog-progress-30.json",
            ]))))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .noInstallableAvailable)
    }

    @Test("tag 页资产 path 越界（页面数据不可信）→ 整页拒绝 fail-closed")
    func checkRejectsPageWithOffScopePath() async throws {
        // 2026-10-07：页面只提供名字集合——任何越界 path 由页面解析器整页拒绝，
        // 注入面从「URL 白名单过滤」前移为「页面形状 fail-closed」。
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(
            body: Self.tagPageHTML([fixture.pointerAssetName],
                                   pathFor: { _ in "https://evil.example.com/catalog.json" }))))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .verificationFailed)
    }

    @Test("pointer 文法边界：0/负数/非数字/Int64 溢出 → 不进入候选")
    func checkPointerVersionGrammarEdges() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(
            body: Self.tagPageHTML([
                "medical-data-catalog-installable-0.json",
                "medical-data-catalog-installable--1.json",
                "medical-data-catalog-installable-30x.json",
                "medical-data-catalog-installable-99999999999999999999.json",
            ]))))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .noInstallableAvailable)
    }

    // MARK: - 失败态归约

    @Test("Release tag 404 → unavailable（不呈「已是最新」）")
    func checkReportsUnavailableOn404() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(statusCode: 404)))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .unavailable)
    }

    @Test("410 → unavailable")
    func checkReportsUnavailableOn410() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(statusCode: 410)))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .unavailable)
    }

    @Test("429 + Retry-After → rateLimited 携带可重试时间")
    func checkReportsRateLimitedWithRetryAfter() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(
            statusCode: 429, headers: ["Retry-After": "120"])))
        let resolver = Self.makeResolver(fixture: fixture)
        let outcome = try await resolver.check()
        #expect(outcome.state == .rateLimited(
            retryAfter: MedicalCatalogFixture.clock.addingTimeInterval(120)))
    }

    @Test("403 + x-ratelimit-reset → rateLimited 携带 epoch 时间")
    func checkReportsRateLimitedWithResetEpoch() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        let resetDate = MedicalCatalogFixture.clock.addingTimeInterval(300)
        Self.apply((MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(
            statusCode: 403, headers: ["x-ratelimit-reset": String(Int(resetDate.timeIntervalSince1970))])))
        let resolver = Self.makeResolver(fixture: fixture)
        let outcome = try await resolver.check()
        #expect(outcome.state == .rateLimited(retryAfter: Date(timeIntervalSince1970: resetDate.timeIntervalSince1970)))
    }

    @Test("403 无重试时间头 → rateLimited(nil)")
    func checkRateLimitedWithoutRetryInfoYieldsNilDate() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(statusCode: 403)))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .rateLimited(retryAfter: nil))
    }

    @Test("5xx → networkUnavailable")
    func checkReportsNetworkUnavailableOn5xx() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(statusCode: 503)))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .networkUnavailable)
    }

    @Test("传输失败（断流）→ networkUnavailable")
    func checkReportsNetworkUnavailableOnTransportFailure() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(
            body: Data("x".utf8), failEveryRequest: true)))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .networkUnavailable)
    }

    @Test("400 → verificationFailed")
    func checkReportsVerificationFailedOn400() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(statusCode: 400)))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .verificationFailed)
    }

    @Test("tag 页畸形（无 __NEXT_DATA__/非 JSON）→ verificationFailed（fail-closed）")
    func checkFailsClosedOnMalformedInventory() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(body: Data("{not json".utf8))))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .verificationFailed)
    }

    @Test("tag 页体超 8 MiB 上限 → 中止传输 → verificationFailed")
    func checkBoundsInventoryBody() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(
            body: Data(repeating: 0, count: (8 << 20) + 1))))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .verificationFailed)
    }

    @Test("pointer 被攻击者重签（非 pinned root 密钥）→ verificationFailed")
    func checkFailsClosedOnTamperedPointer() async throws {
        let fixture = try MedicalCatalogFixture.make()
        let attacker = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp(); attacker.cleanUp() }
        Self.resetStubs()
        Self.apply(Self.installRoutes(fixture, pointerBody: attacker.signedPointerJSON))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .verificationFailed)
    }

    @Test("pointer 体超 2 MB 上限 → 中止传输 → verificationFailed")
    func checkBoundsPointerBody() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply(Self.installRoutes(
            fixture, pointerBody: Data(repeating: 0, count: (2 << 20) + 1)))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .verificationFailed)
    }

    @Test("pointer 404（inventory 200 但资产缺失=发布方不一致）→ verificationFailed")
    func checkPointer404FailsClosed() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        var routes = Self.installRoutes(fixture)
        routes[1] = (URL(string: Self.pointerURL(fixture.pointerAssetName))!,
                     URLProtocolStub.Script(statusCode: 404))
        Self.apply(routes)
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .verificationFailed)
    }

    @Test("pointer 429 带 Retry-After → rateLimited")
    func checkPointer429MapsToRateLimited() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        var routes = Self.installRoutes(fixture)
        routes[1] = (URL(string: Self.pointerURL(fixture.pointerAssetName))!,
                     URLProtocolStub.Script(statusCode: 429, headers: ["Retry-After": "60"]))
        Self.apply(routes)
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .rateLimited(
            retryAfter: MedicalCatalogFixture.clock.addingTimeInterval(60)))
    }

    @Test("无 pinned root（未 provisioning）→ unavailable 且零网络请求")
    func checkFailsClosedWithoutPinnedRoot() async throws {
        Self.resetStubs()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let resolver = MedicalCatalogReleaseResolver(pinnedRootJSON: nil,
                                                     makeVerifier: nil,
                                                     hasher: CryptoKitContentHasher(),
                                                     session: URLSession(configuration: configuration),
                                                     now: { MedicalCatalogFixture.clock })
        #expect(try await resolver.check().state == .unavailable)
        // 按本套件 URL 前缀过滤（全局日志有跨套件并发写，评审修复；同一 cnb.cool
        // 主机上的 fetcher 包请求必须排除在「零网络」断言之外）
        let ownHits = URLProtocolStub.requestLog.filter {
            $0.url.absoluteString.hasPrefix("https://cnb.cool/robinhoo1973/Resources/-/releases/tag/medical-data")
                || $0.url.absoluteString.hasPrefix(MedicalCatalogReleaseProtocol.releaseBaseURL
                                                   + "/medical-data-catalog-")
        }
        #expect(ownHits.isEmpty)
    }

    // MARK: - 重定向守卫（直接测 delegate 判定；URLSession 跟随行为属系统内部，钉此无益）

    @Test("重定向守卫：白名单内 URL 放行")
    func redirectGuardAllowsAllowlistedURL() throws {
        let box = RequestBox()
        let delegate = MedicalCatalogBoundedDataDelegate(maxBytes: 10, allowsURL: { _ in true })
        let url = try #require(URL(string: "https://cnb.cool/x"))
        let task = URLSession.shared.dataTask(with: url)
        let redirect = try #require(HTTPURLResponse(url: url, statusCode: 301, httpVersion: nil, headerFields: nil))
        delegate.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: redirect,
                            newRequest: URLRequest(url: url)) { box.set($0) }
        #expect(box.called && box.value != nil)
        task.cancel()
    }

    @Test("重定向守卫：越白名单主机/超跳数上限 → 拒绝（nil）")
    func redirectGuardRejectsOffListHost() throws {
        let box = RequestBox()
        let delegate = MedicalCatalogBoundedDataDelegate(maxBytes: 10,
                                                         allowsURL: { $0.host == "api.cnb.cool" })
        let github = try #require(URL(string: "https://api.cnb.cool/x"))
        let evil = try #require(URL(string: "https://evil.example.com/x"))
        let task = URLSession.shared.dataTask(with: github)
        let redirect = try #require(HTTPURLResponse(url: github, statusCode: 301, httpVersion: nil, headerFields: nil))
        delegate.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: redirect,
                            newRequest: URLRequest(url: evil)) { box.set($0) }
        #expect(box.called && box.value == nil)

        // 跳数上限：独立 delegate（上方 evil 拒绝已消耗 1 跳计数）——连续放行
        // maxRedirects 次后下一次拒绝
        let hopDelegate = MedicalCatalogBoundedDataDelegate(maxBytes: 10,
                                                            allowsURL: { $0.host == "api.cnb.cool" })
        for _ in 0..<MedicalCatalogBoundedDataDelegate.maxRedirects {
            let hop = RequestBox()
            hopDelegate.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: redirect,
                                   newRequest: URLRequest(url: github)) { hop.set($0) }
            #expect(hop.called && hop.value != nil)
        }
        let final = RequestBox()
        hopDelegate.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: redirect,
                               newRequest: URLRequest(url: github)) { final.set($0) }
        #expect(final.called && final.value == nil)
        task.cancel()
    }

    @Test("重定向被拒后任务以 3xx 结束 → 归约 networkUnavailable")
    func check3xxResponseMapsToNetworkUnavailable() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(statusCode: 301)))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .networkUnavailable)
    }

    // MARK: - ETag / 304

    @Test("304 复用匹配缓存体并重验——路由损坏仍返回验签结果")
    func checkReusesCachedBodyOn304() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        var routes = Self.installRoutes(fixture)
        routes[0] = (MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(
            headers: ["ETag": "inv-1"], body: Self.tagPageHTML([fixture.pointerAssetName]), etag304: true))
        Self.apply(routes)
        let resolver = Self.makeResolver(fixture: fixture)
        guard case .updateAvailable = (try await resolver.check()).state else {
            Issue.record("首次检查应发现更新")
            return
        }
        // 缓存后把 tag 页体换成垃圾：304 命中必须复用旧体，绝不解析新体
        routes[0] = (MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(
            headers: ["ETag": "inv-1"], body: Data("{broken".utf8), etag304: true))
        Self.apply(routes)
        guard case .updateAvailable = (try await resolver.check()).state else {
            Issue.record("304 命中缓存必须复用已验证响应体")
            return
        }
    }

    @Test("pointer 304 复用缓存体（重验签名）")
    func checkPointer304ReusesCache() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        var routes = Self.installRoutes(fixture)
        routes[1] = (URL(string: Self.pointerURL(fixture.pointerAssetName))!,
                     URLProtocolStub.Script(headers: ["ETag": "ptr-1"],
                                            body: fixture.signedPointerJSON, etag304: true))
        Self.apply(routes)
        let resolver = Self.makeResolver(fixture: fixture)
        guard case .updateAvailable = (try await resolver.check()).state else {
            Issue.record("首次检查应发现更新")
            return
        }
        // 缓存后把 pointer 体换成垃圾：304 命中必须复用旧体并重验
        routes[1] = (URL(string: Self.pointerURL(fixture.pointerAssetName))!,
                     URLProtocolStub.Script(headers: ["ETag": "ptr-1"],
                                            body: Data("{broken".utf8), etag304: true))
        Self.apply(routes)
        guard case .updateAvailable = (try await resolver.check()).state else {
            Issue.record("pointer 304 命中缓存必须复用并重验")
            return
        }
    }

    @Test("304 无缓存 → 最多一次无条件重试；重试仍 304 → fail-closed")
    func checkHandles304WithoutCache() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(statusCode: 304)))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .verificationFailed)
        #expect(inventoryHits() == 2, "304 无缓存应恰好一次无条件重试，实际请求 \(inventoryHits()) 次")
    }

    // MARK: - 反回退 floor

    @Test("验签通过即推进 floor——metadata 信任与安装结果无关")
    func floorAdvancesOnVerifiedCheck() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply(Self.installRoutes(fixture))
        let trust = MedicalCatalogTrustStore(fileURL: fixture.directory.appendingPathComponent("floor.json"))
        let resolver = Self.makeResolver(fixture: fixture, trust: trust)
        guard case .updateAvailable = (try await resolver.check()).state else {
            Issue.record("预期 updateAvailable")
            return
        }
        #expect(trust.observedFloor?.catalogVersion == 30)
        let digest = try fixture.candidate().signedPointerDigest
        #expect(trust.observedFloor?.payloadDigest == digest)
    }

    @Test("发布方回退到已见低版本 → 本机数据一致呈 upToDate")
    func floorRollbackShowsUpToDateWhenSameData() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply(Self.installRoutes(fixture))
        let trust = MedicalCatalogTrustStore(fileURL: fixture.directory.appendingPathComponent("floor.json"))
        try trust.accept(try fixture.candidate { $0["catalogVersion"] = 31 })
        let local = MedicalCatalogInstalledVersion(schemaVersion: 7,   // CNB v7-only 契约
                                                   dataVersion: fixture.signedExpectation.dataVersion)
        let resolver = Self.makeResolver(fixture: fixture, trust: trust, local: local)
        #expect(try await resolver.check().state == .upToDate)
    }

    @Test("发布方回退到已见低版本 → 本机无一致数据呈 noInstallableAvailable")
    func floorRollbackShowsNoInstallableWhenNoLocal() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply(Self.installRoutes(fixture))
        let trust = MedicalCatalogTrustStore(fileURL: fixture.directory.appendingPathComponent("floor.json"))
        try trust.accept(try fixture.candidate { $0["catalogVersion"] = 31 })
        let resolver = Self.makeResolver(fixture: fixture, trust: trust)
        #expect(try await resolver.check().state == .noInstallableAvailable)
    }

    @Test("同版本异摘要（equivocation）→ verificationFailed")
    func floorEquivocationFailsClosed() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        // 同 v30、不同 dataVersion 的重签指针 → 不同 signedPointerDigest
        let equivocal = try fixture.signedPointer { $0["dataVersion"] = String(repeating: "1", count: 64) }
        Self.apply(Self.installRoutes(fixture, pointerBody: equivocal))
        let trust = MedicalCatalogTrustStore(fileURL: fixture.directory.appendingPathComponent("floor.json"))
        try trust.accept(try fixture.candidate())
        let resolver = Self.makeResolver(fixture: fixture, trust: trust)
        #expect(try await resolver.check().state == .verificationFailed)
    }

    // MARK: - 单飞与取消

    @Test("单飞：检查在途时并发请求返回 checking，不二发")
    func checkSingleFlight() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        var routes = Self.installRoutes(fixture)
        // 分块延时下发：让首次检查在途，制造确定性并发窗口
        routes[0] = (MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(
            body: Self.tagPageHTML([fixture.pointerAssetName]),
            chunkBytes: 64, chunkDelay: 0.3))
        Self.apply(routes)
        let resolver = Self.makeResolver(fixture: fixture)
        let first = Task { try await resolver.check() }
        try await waitForRequest(MedicalCatalogReleaseResolver.tagPageURL)
        #expect(try await resolver.check().state == .checking)
        // 一次取值再断言：诊断信息取真实 state，避免第二次 await 与 try?（L0 [1/18] try? 禁令）
        let firstOutcome = try await first.value
        guard case .updateAvailable = firstOutcome.state else {
            Issue.record("首个检查应最终返回 updateAvailable，实际 \(String(describing: firstOutcome.state))")
            return
        }
        #expect(inventoryHits() == 1)
    }

    @Test("取消检查 → CancellationError 传播，isChecking 复位无状态污染")
    func checkCancellationPropagates() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        var routes = Self.installRoutes(fixture)
        routes[0] = (MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(
            body: Self.tagPageHTML([fixture.pointerAssetName]),
            chunkBytes: 64, chunkDelay: 0.3))
        Self.apply(routes)
        let resolver = Self.makeResolver(fixture: fixture)
        let task = Task { try await resolver.check() }
        try await waitForRequest(MedicalCatalogReleaseResolver.tagPageURL)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // 「无状态污染」兑现：换快速脚本再查 → isChecking 已复位、正常发现更新
        routes[0] = (MedicalCatalogReleaseResolver.tagPageURL, URLProtocolStub.Script(
            body: Self.tagPageHTML([fixture.pointerAssetName])))
        Self.apply(routes)
        guard case .updateAvailable = (try await resolver.check()).state else {
            Issue.record("取消后重查应正常发现更新")
            return
        }
    }

    // MARK: - 有界 delegate 直测（弱钉加固：字节上限必须与「JSON 非法」可区分）

    @Test("有界 delegate 超限即停止累计并置 exceeded")
    func boundedDelegateStopsAccumulatingAfterLimit() {
        let delegate = MedicalCatalogBoundedDataDelegate(maxBytes: 4, allowsURL: { _ in true })
        let task = URLSession.shared.dataTask(with: MedicalCatalogReleaseResolver.tagPageURL)
        delegate.urlSession(URLSession.shared, dataTask: task, didReceive: Data([1, 2, 3, 4]))
        #expect(!delegate.exceeded)
        delegate.urlSession(URLSession.shared, dataTask: task, didReceive: Data([5]))
        #expect(delegate.exceeded)
        // 语义钉：跨界 chunk 已收（内存上界 = cap + 单 chunk），其后一律拒收
        #expect(delegate.accumulated.count == 5, "跨界 chunk 计入后不再累计")
        delegate.urlSession(URLSession.shared, dataTask: task, didReceive: Data([6]))
        #expect(delegate.accumulated.count == 5, "超限后不再累计")
        task.cancel()
    }

    // MARK: - ETag 缓存直测

    @Test("ETag 缓存：单条超 limit 拒存")
    func etagStoreRejectsEntryOverLimit() {
        let cache = MedicalCatalogETagCache()
        let url = URL(string: "https://api.cnb.cool/x")!
        cache.store(etag: "e", body: Data(repeating: 0, count: 10), for: url, limit: 5)
        #expect(cache.entry(for: url) == nil)
    }

    @Test("ETag 缓存：总量超限拒存且不驱逐旧条目（304 语义优先稳定）")
    func etagStoreKeepsOldEntryOnOverflow() {
        let cache = MedicalCatalogETagCache(maxTotalBytes: 100)
        let first = URL(string: "https://api.cnb.cool/a")!
        let second = URL(string: "https://api.cnb.cool/b")!
        cache.store(etag: "e1", body: Data(repeating: 0, count: 80), for: first, limit: 200)
        cache.store(etag: "e2", body: Data(repeating: 0, count: 30), for: second, limit: 200)
        #expect(cache.entry(for: second) == nil)
        #expect(cache.entry(for: first) != nil, "旧条目不得被超限写入驱逐")
    }

    @Test("ETag 缓存：同键替换修正记账、后续写入按新总量判定")
    func etagStoreReplaceUpdatesTotalBytes() {
        let cache = MedicalCatalogETagCache(maxTotalBytes: 100)
        let url = URL(string: "https://api.cnb.cool/a")!
        cache.store(etag: "e1", body: Data(repeating: 0, count: 30), for: url, limit: 200)
        cache.store(etag: "e2", body: Data(repeating: 0, count: 50), for: url, limit: 200)
        #expect(cache.entry(for: url)?.body.count == 50)
        // 30+50 已替换为 50：再放 60（总计 110 > 100）应拒，50 保留
        let other = URL(string: "https://api.cnb.cool/b")!
        cache.store(etag: "e3", body: Data(repeating: 0, count: 60), for: other, limit: 200)
        #expect(cache.entry(for: other) == nil)
        #expect(cache.entry(for: url)?.body.count == 50)
    }

    @Test("ETag 缓存：未知 URL 返回 nil")
    func etagEntryReturnsNilForUnknownURL() {
        let cache = MedicalCatalogETagCache()
        #expect(cache.entry(for: URL(string: "https://api.cnb.cool/none")!) == nil)
    }
}

/// SU-M15-MEDCATALOG · pointer 名文法钉：Swift 侧 `parsePointerAssetName` 是
/// Go `names.go`（pointerNamePattern / ParsePointerAssetName）的逐项镜像。
/// CI #655 实证：15/16 字节 stamp 门差一字节时 resolver 恒呈
/// noInstallableAvailable，且本文件在 Linux 编译为空（零本地信号）——
/// 文法必须有自己的 macOS 直测钉，而不是只由 resolver 集成路径间接触达。
@Suite("SU-M15-MEDCATALOG · pointer 名文法钉（Go names.go 镜像）", .serialized)
struct MedicalCatalogPointerNameTests {

    @Test("v2 时间戳名解析（16 字节 stamp 含 T）", arguments: [
        ("medical-data-catalog-installable-30-20260926T120000Z.json", true, Int64(30), "20260926T120000Z"),
        ("medical-data-catalog-progress-21-20261001T120000Z.json", false, Int64(21), "20261001T120000Z"),
        ("medical-data-catalog-installable-1-20260101T000000Z.json", true, Int64(1), "20260101T000000Z"),
    ])
    func parsesV2Names(_ name: String, _ installable: Bool, _ version: Int64, _ stamp: String) {
        let parsed = MedicalCatalogReleaseProtocol.parsePointerAssetName(name)
        #expect(parsed?.installable == installable)
        #expect(parsed?.catalogVersion == version)
        #expect(parsed?.timestamp == stamp)
    }

    @Test("legacy 纯数字名仅作候选定位（无 stamp）", arguments: [
        ("medical-data-catalog-installable-30.json", true, Int64(30)),
        ("medical-data-catalog-progress-9.json", false, Int64(9)),
    ])
    func parsesLegacyNames(_ name: String, _ installable: Bool, _ version: Int64) {
        let parsed = MedicalCatalogReleaseProtocol.parsePointerAssetName(name)
        #expect(parsed?.installable == installable)
        #expect(parsed?.catalogVersion == version)
        #expect(parsed?.timestamp == nil)
    }

    @Test("形状违规拒绝（Go 正则锚定镜像）", arguments: [
        "README.md",
        "medical-data-catalog-installable-30-20260926T120000Z.txt",
        "medical-data-catalog-installable-30-20260926T120000Z.json-extra",
        "medical-data-catalog-installable-30-20260926T120000Z",
        "medical-data-catalog-installable--30-20260926T120000Z.json",
        "medical-data-catalog-installable-0-20260926T120000Z.json",
        "medical-data-catalog-installable-007-20260926T120000Z.json",
        "medical-data-catalog-installable-30-20260926T12000Z.json",   // 15 字节旧形
        "medical-data-catalog-installable-30-20260926120000Z.json",  // 无 T
        "medical-data-catalog-installable-30-20260926T120000ZZ.json",
        "medical-data-catalog-other-30-20260926T120000Z.json",
        "medical-data-catalog-installable-30-.json",
        "medical-data-catalog-installable-30-20260926T120000Z-extra.json",
        "medical-data-catalog-installable-99999999999999999999-20260926T120000Z.json",   // 20 位版本
    ])
    func rejectsMalformedNames(_ name: String) {
        #expect(MedicalCatalogReleaseProtocol.parsePointerAssetName(name) == nil)
    }

    @Test("日历非法 stamp 拒绝（Go time.Parse 回环镜像）", arguments: [
        "medical-data-catalog-installable-30-20261340T120000Z.json",   // 月 13
        "medical-data-catalog-installable-30-20260926T240000Z.json",   // 时 24
        "medical-data-catalog-installable-30-20260926T126000Z.json",   // 分 60
        "medical-data-catalog-installable-30-20260926T120060Z.json",   // 秒 60
    ])
    func rejectsInvalidCalendarStamps(_ name: String) {
        #expect(MedicalCatalogReleaseProtocol.parsePointerAssetName(name) == nil)
    }
}
#endif
