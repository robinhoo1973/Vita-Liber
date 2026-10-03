import Foundation
import Domain
import Testing

#if os(iOS) || os(macOS)
// linux-blind: URLSession/URLProtocol 传输语义在 macOS CI 真跑（家族 N/O/P 同规）
@testable import Infrastructure

/// SU-M15-MEDCATALOG · binds: SU-M15-MEDCATALOG（TC-M15-12 检查 resolver，委员会测试席）
/// SP-64 检查 resolver 行为钉（tech-spec §5.53 / ui-ux §5.12.4）：
/// inventory → 最高 installable pointer → pinned root 验签 → floor 反回退 →
/// 本地比较；ETag/304、限流、404/410/5xx、取消、单飞、字节上限、主机白名单、
/// 重定向与 delegate/ETag 缓存直测。夹具复用 `MedicalCatalogFixture`（同目标）。
///
/// 主机属主纪律（2026-09-27 测试席评审修复）：本套件占 **api.github.com**
/// （inventory）+ **objects.githubusercontent.com**（pointer）——github.com 由
/// fetcher 传输套件独占，不再双重占用（URLProtocolStub 静态表跨套件并行）。
@Suite("SU-M15-MEDCATALOG · SP-64 检查 resolver 行为钉", .serialized)
struct MedicalCatalogReleaseResolverTests {

    // MARK: - 组装助手

    private static func resetStubs() {
        URLProtocolStub.reset(host: "api.github.com")
        URLProtocolStub.reset(host: "objects.githubusercontent.com")
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: configuration)
    }

    private static func inventoryJSON(_ assets: [(name: String, url: String)]) -> Data {
        let array = assets.map { ["name": $0.name, "browser_download_url": $0.url] as [String: String] }
        return try! JSONSerialization.data(withJSONObject: ["assets": array]) // try?-ok: 测试夹具 JSON 由字面量字典构造，无失败路径
    }

    /// pointer 由本套件独占主机服务（见套件头注）。
    private static func pointerURL(_ assetName: String) -> String {
        "https://objects.githubusercontent.com/medical-data/" + assetName
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

    /// 发布 inventory + installable-30 pointer 的标准路由（逐键写入——整字典赋值
    /// 会跨套件清表，违反 URLProtocolStub 主机作用域纪律）。
    private static func installRoutes(_ fixture: MedicalCatalogFixture,
                                      pointerBody: Data? = nil) -> [(URL, URLProtocolStub.Script)] {
        [
            (MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(
                body: inventoryJSON([(fixture.pointerAssetName, pointerURL(fixture.pointerAssetName))]))),
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
        URLProtocolStub.requestLog.filter { $0.url == MedicalCatalogReleaseResolver.inventoryURL }.count
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
        #expect(candidate.schemaVersion == 5)
        let expected = try fixture.candidate()
        #expect(outcome.candidate == expected)
    }

    @Test("resolver accepts a verified physical v6 pointer")
    func checkFindsPhysicalV6Update() async throws {
        let fixture = try MedicalCatalogFixture.make(schemaVersion: 6)
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply(Self.installRoutes(fixture))
        let resolver = Self.makeResolver(fixture: fixture)
        let outcome = try await resolver.check()
        guard case .updateAvailable(let candidate) = outcome.state else {
            Issue.record("v6 pointer should produce updateAvailable, actual=\(outcome.state)")
            return
        }
        #expect(candidate.schemaVersion == 6)
        #expect(candidate.dataVersion == fixture.signedExpectation.dataVersion)
    }

    @Test("本地 (schemaVersion,dataVersion) 一致 → upToDate，不重复下载")
    func checkReportsUpToDateWhenLocalDataMatches() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply(Self.installRoutes(fixture))
        let local = MedicalCatalogInstalledVersion(schemaVersion: 5,
                                                   dataVersion: fixture.signedExpectation.dataVersion)
        let resolver = Self.makeResolver(fixture: fixture, local: local)
        let outcome = try await resolver.check()
        guard outcome.state == .upToDate, outcome.candidate == nil else {
            Issue.record("本地数据一致应呈 upToDate 且无候选，实际 \(outcome.state) / candidate=\(String(describing: outcome.candidate))")
            return
        }
    }

    @Test("matching local physical v6 schema and data version reports upToDate")
    func checkReportsUpToDateForPhysicalV6() async throws {
        let fixture = try MedicalCatalogFixture.make(schemaVersion: 6)
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply(Self.installRoutes(fixture))
        let local = MedicalCatalogInstalledVersion(schemaVersion: 6, dataVersion: fixture.signedExpectation.dataVersion)
        let resolver = Self.makeResolver(fixture: fixture, local: local)
        let outcome = try await resolver.check()
        #expect(outcome.state == .upToDate)
        #expect(outcome.candidate == nil)
    }

    @Test("Release 只有 progress pointer → noInstallableAvailable，不误报最新/更新")
    func checkReportsNoInstallableWhenOnlyProgress() async throws {
        let fixture = try MedicalCatalogFixture.make(installable: false)
        defer { fixture.cleanUp() }
        let progressName = MedicalCatalogReleaseProtocol.pointerAssetName(installable: false, catalogVersion: 30)
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(
            body: Self.inventoryJSON([(progressName, Self.pointerURL(progressName))]))))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .noInstallableAvailable)
    }

    @Test("高序号 progress 不遮蔽低序号 installable——候选只看 installable")
    func checkPicksHighestInstallableIgnoringProgress() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        // 伪造的 progress-40 只需占名——解析器永不下载它
        let progressName = MedicalCatalogReleaseProtocol.pointerAssetName(installable: false, catalogVersion: 40)
        Self.resetStubs()
        Self.apply([
            (MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(
                body: Self.inventoryJSON([
                    (progressName, Self.pointerURL(progressName)),
                    (fixture.pointerAssetName, Self.pointerURL(fixture.pointerAssetName)),
                ]))),
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

    @Test("资产名不在 pointer 文法内/URL 越白名单 → 不进入候选")
    func checkIgnoresJunkAndOffListAssets() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(
            body: Self.inventoryJSON([
                ("medical-data-catalog-installable-30.json", "https://evil.example.com/p"),
                ("medical-data-catalog-installable-30.json", "http://github.com/robinhoo1973/Vita-Liber/x.json"),
                ("README.md", "https://github.com/robinhoo1973/Vita-Liber/README.md"),
                ("medical-data-catalog-progress-30.json", Self.pointerURL("medical-data-catalog-progress-30.json")),
            ]))))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .noInstallableAvailable)
    }

    @Test("pointer 文法边界：0/负数/非数字/Int64 溢出 → 不进入候选")
    func checkPointerVersionGrammarEdges() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(
            body: Self.inventoryJSON([
                ("medical-data-catalog-installable-0.json", Self.pointerURL("x")),
                ("medical-data-catalog-installable--1.json", Self.pointerURL("x")),
                ("medical-data-catalog-installable-30x.json", Self.pointerURL("x")),
                ("medical-data-catalog-installable-99999999999999999999.json", Self.pointerURL("x")),
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
        Self.apply((MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(statusCode: 404)))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .unavailable)
    }

    @Test("410 → unavailable")
    func checkReportsUnavailableOn410() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(statusCode: 410)))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .unavailable)
    }

    @Test("429 + Retry-After → rateLimited 携带可重试时间")
    func checkReportsRateLimitedWithRetryAfter() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(
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
        Self.apply((MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(
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
        Self.apply((MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(statusCode: 403)))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .rateLimited(retryAfter: nil))
    }

    @Test("5xx → networkUnavailable")
    func checkReportsNetworkUnavailableOn5xx() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(statusCode: 503)))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .networkUnavailable)
    }

    @Test("传输失败（断流）→ networkUnavailable")
    func checkReportsNetworkUnavailableOnTransportFailure() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(
            body: Data("x".utf8), failEveryRequest: true)))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .networkUnavailable)
    }

    @Test("400 → verificationFailed")
    func checkReportsVerificationFailedOn400() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(statusCode: 400)))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .verificationFailed)
    }

    @Test("inventory 畸形 JSON → verificationFailed（fail-closed）")
    func checkFailsClosedOnMalformedInventory() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(body: Data("{not json".utf8))))
        let resolver = Self.makeResolver(fixture: fixture)
        #expect(try await resolver.check().state == .verificationFailed)
    }

    @Test("inventory 体超 4 MB 上限 → 中止传输 → verificationFailed")
    func checkBoundsInventoryBody() async throws {
        let fixture = try MedicalCatalogFixture.make()
        defer { fixture.cleanUp() }
        Self.resetStubs()
        Self.apply((MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(
            body: Data(repeating: 0, count: (4 << 20) + 1))))
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
        // 按本套件主机过滤（全局日志有跨套件并发写，评审修复）
        let ownHits = URLProtocolStub.requestLog.filter {
            $0.url.host == "api.github.com" || $0.url.host == "objects.githubusercontent.com"
        }
        #expect(ownHits.isEmpty)
    }

    // MARK: - 重定向守卫（直接测 delegate 判定；URLSession 跟随行为属系统内部，钉此无益）

    @Test("重定向守卫：白名单内 URL 放行")
    func redirectGuardAllowsAllowlistedURL() throws {
        let box = RequestBox()
        let delegate = MedicalCatalogBoundedDataDelegate(maxBytes: 10, allowsURL: { _ in true })
        let url = try #require(URL(string: "https://api.github.com/x"))
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
                                                         allowsURL: { $0.host == "api.github.com" })
        let github = try #require(URL(string: "https://api.github.com/x"))
        let evil = try #require(URL(string: "https://evil.example.com/x"))
        let task = URLSession.shared.dataTask(with: github)
        let redirect = try #require(HTTPURLResponse(url: github, statusCode: 301, httpVersion: nil, headerFields: nil))
        delegate.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: redirect,
                            newRequest: URLRequest(url: evil)) { box.set($0) }
        #expect(box.called && box.value == nil)

        // 跳数上限：独立 delegate（上方 evil 拒绝已消耗 1 跳计数）——连续放行
        // maxRedirects 次后下一次拒绝
        let hopDelegate = MedicalCatalogBoundedDataDelegate(maxBytes: 10,
                                                            allowsURL: { $0.host == "api.github.com" })
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
        Self.apply((MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(statusCode: 301)))
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
        routes[0] = (MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(
            headers: ["ETag": "inv-1"], body: Self.inventoryJSON(
                [(fixture.pointerAssetName, Self.pointerURL(fixture.pointerAssetName))]), etag304: true))
        Self.apply(routes)
        let resolver = Self.makeResolver(fixture: fixture)
        guard case .updateAvailable = (try await resolver.check()).state else {
            Issue.record("首次检查应发现更新")
            return
        }
        // 缓存后把 inventory 体换成垃圾：304 命中必须复用旧体，绝不解析新体
        routes[0] = (MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(
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
        Self.apply((MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(statusCode: 304)))
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
        let local = MedicalCatalogInstalledVersion(schemaVersion: 5,
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
        routes[0] = (MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(
            body: Self.inventoryJSON([(fixture.pointerAssetName, Self.pointerURL(fixture.pointerAssetName))]),
            chunkBytes: 64, chunkDelay: 0.3))
        Self.apply(routes)
        let resolver = Self.makeResolver(fixture: fixture)
        let first = Task { try await resolver.check() }
        try await waitForRequest(MedicalCatalogReleaseResolver.inventoryURL)
        #expect(try await resolver.check().state == .checking)
        guard case .updateAvailable = (try await first.value).state else {
            Issue.record("首个检查应最终返回 updateAvailable")
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
        routes[0] = (MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(
            body: Self.inventoryJSON([(fixture.pointerAssetName, Self.pointerURL(fixture.pointerAssetName))]),
            chunkBytes: 64, chunkDelay: 0.3))
        Self.apply(routes)
        let resolver = Self.makeResolver(fixture: fixture)
        let task = Task { try await resolver.check() }
        try await waitForRequest(MedicalCatalogReleaseResolver.inventoryURL)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        // 「无状态污染」兑现：换快速脚本再查 → isChecking 已复位、正常发现更新
        routes[0] = (MedicalCatalogReleaseResolver.inventoryURL, URLProtocolStub.Script(
            body: Self.inventoryJSON([(fixture.pointerAssetName, Self.pointerURL(fixture.pointerAssetName))])))
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
        let task = URLSession.shared.dataTask(with: MedicalCatalogReleaseResolver.inventoryURL)
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
        let url = URL(string: "https://api.github.com/x")!
        cache.store(etag: "e", body: Data(repeating: 0, count: 10), for: url, limit: 5)
        #expect(cache.entry(for: url) == nil)
    }

    @Test("ETag 缓存：总量超限拒存且不驱逐旧条目（304 语义优先稳定）")
    func etagStoreKeepsOldEntryOnOverflow() {
        let cache = MedicalCatalogETagCache(maxTotalBytes: 100)
        let first = URL(string: "https://api.github.com/a")!
        let second = URL(string: "https://api.github.com/b")!
        cache.store(etag: "e1", body: Data(repeating: 0, count: 80), for: first, limit: 200)
        cache.store(etag: "e2", body: Data(repeating: 0, count: 30), for: second, limit: 200)
        #expect(cache.entry(for: second) == nil)
        #expect(cache.entry(for: first) != nil, "旧条目不得被超限写入驱逐")
    }

    @Test("ETag 缓存：同键替换修正记账、后续写入按新总量判定")
    func etagStoreReplaceUpdatesTotalBytes() {
        let cache = MedicalCatalogETagCache(maxTotalBytes: 100)
        let url = URL(string: "https://api.github.com/a")!
        cache.store(etag: "e1", body: Data(repeating: 0, count: 30), for: url, limit: 200)
        cache.store(etag: "e2", body: Data(repeating: 0, count: 50), for: url, limit: 200)
        #expect(cache.entry(for: url)?.body.count == 50)
        // 30+50 已替换为 50：再放 60（总计 110 > 100）应拒，50 保留
        let other = URL(string: "https://api.github.com/b")!
        cache.store(etag: "e3", body: Data(repeating: 0, count: 60), for: other, limit: 200)
        #expect(cache.entry(for: other) == nil)
        #expect(cache.entry(for: url)?.body.count == 50)
    }

    @Test("ETag 缓存：未知 URL 返回 nil")
    func etagEntryReturnsNilForUnknownURL() {
        let cache = MedicalCatalogETagCache()
        #expect(cache.entry(for: URL(string: "https://api.github.com/none")!) == nil)
    }
}
#endif
