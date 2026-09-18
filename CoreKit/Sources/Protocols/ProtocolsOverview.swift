import Foundation

/// tech-spec §1.1 分层第三层：Protocols —— 存储与系统服务的能力锚点。
/// M0 最小面（评审 S1-3：§3.1② 要求 CoreKit 三目标骨架，Domain/Protocols/Infrastructure）：
/// Feature 面向协议、Infrastructure 提供实现；跨 Feature 通信只经 Domain 实体与本层协议。
///
/// 第八轮全仓审查修复：DatabaseContext/ReadAccess/WriteAccess 三元组（M0
/// 最小面空标记脚手架）全仓零实现、零引用——各 Store 直接持有 DatabaseWriter，
/// 协议层从未强制「同一事务上下文」纪律，协议演进时也无人发现没有实现方。
/// 已删除（§4.4 纪律由 Infrastructure 的 DatabaseWriter 注入点强制执行，
/// tech-spec 保留描述）。
///
/// 2026-09-19 结构轮：原 Persistence.swift 混置 AuditLogging 与 InventoryScanner
/// 两个无关域，已按「一文件一协议域」拆为 AuditLogging.swift / InventoryScanner.swift；
/// 本文件仅承载本层的用途说明（协议名 → 文件名一一对应，新增协议请单独建文件）。
