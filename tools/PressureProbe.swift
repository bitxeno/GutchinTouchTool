import Foundation
import CoreGraphics

// PressureProbe — 独立诊断工具：探测 MTTouch 偏移 40/44/48 区域与鼠标事件压力，
// 用于校准 "物理按压 vs 轻点来点按" 的区分信号。
//
// 用法:  swift tools/PressureProbe.swift
// 操作:  轻点触控板几次（tap），再用力按几次（click），对比输出。
// 结论:  哪个字段在 tap 和 click 之间数值明显不同，它就是可用的门控信号。

// MARK: - MultitouchSupport bindings (same approach as TrackpadMonitor)

typealias MTDeviceRef = UnsafeMutableRawPointer

private let multitouchFramework = dlopen(
    "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY)

private typealias MTDeviceCreateListFunc = @convention(c) () -> Unmanaged<CFArray>
private typealias MTRegisterContactFrameCallbackFunc = @convention(c) (MTDeviceRef, @convention(c) (MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void) -> Void
private typealias MTDeviceStartFunc = @convention(c) (MTDeviceRef, Int32) -> Void

// Known MTTouch offsets (verified in GutchinTouchTool on this machine)
let offsetFrame: Int = 0
let offsetFingerID: Int = 24
let offsetNormX: Int = 32
let offsetNormY: Int = 36
// Unattributed fields — the candidates for click force
let offsetA: Int = 40
let offsetB: Int = 44
let offsetC: Int = 48
let offsetMajor: Int = 52
let offsetMinor: Int = 56

final class Probe {
    var stride: Int = 0
    var deviceCount = 0

    // Session state
    var sessionIndex = 0
    var sessionStart: Double?
    var peakFingers = 0
    var maxA: Float = 0, maxB: Float = 0, maxC: Float = 0
    var maxMajor: Float = 0, maxMinor: Float = 0
    var lastLiveA: Float = -1, lastLiveB: Float = -1

    func detectStride(raw: UnsafeMutableRawPointer, numTouches: Int) -> Int {
        let fallback = 80
        guard numTouches >= 2 else { return fallback }
        let frame0 = raw.load(fromByteOffset: offsetFrame, as: Int32.self)
        for candidate in [fallback, 84, 88, 92, 96, 104, 112, 120, 128] {
            let frame1 = raw.load(fromByteOffset: candidate, as: Int32.self)
            if frame1 == frame0 {
                let px = raw.load(fromByteOffset: candidate + offsetNormX, as: Float.self)
                let py = raw.load(fromByteOffset: candidate + offsetNormY, as: Float.self)
                if px >= 0 && px <= 1.5 && py >= 0 && py <= 1.5 { return candidate }
            }
        }
        return fallback
    }

    func handleFrame(rawTouches: UnsafeMutableRawPointer?, numTouches: Int, timestamp: Double) {
        guard let raw = rawTouches, numTouches > 0 else {
            if sessionStart != nil {
                let dur = timestamp - sessionStart!
                print(String(format: "── SESSION #%d 结束  dur=%.2fs  peakFingers=%d", sessionIndex, dur, peakFingers))
                print(String(format: "   max fA=%.4f  max fB=%.4f  max fC=%.4f", maxA, maxB, maxC))
                print(String(format: "   max iA=%d  max iB=%d  max iC=%d", maxA.bitPattern, maxB.bitPattern, maxC.bitPattern))
                print(String(format: "   max major=%.3f  max minor=%.3f", maxMajor, maxMinor))
                print(String(format: "   (float 字段若真实存储 float，其 bitPattern 会是 ~1e9 量级)", ))
                sessionStart = nil
                lastLiveA = -1; lastLiveB = -1
            }
            return
        }

        if stride == 0 && numTouches >= 2 {
            stride = detectStride(raw: raw, numTouches: numTouches)
            print("[probe] touch stride = \(stride) bytes")
        }
        let s = stride > 0 ? stride : 80

        // New session
        if sessionStart == nil {
            sessionIndex += 1
            sessionStart = timestamp
            peakFingers = 0
            maxA = 0; maxB = 0; maxC = 0; maxMajor = 0; maxMinor = 0
        }
        peakFingers = max(peakFingers, numTouches)

        for i in 0..<numTouches {
            let base = i * s
            let fid = raw.load(fromByteOffset: base + offsetFingerID, as: Int32.self)
            let x   = raw.load(fromByteOffset: base + offsetNormX, as: Float.self)
            let y   = raw.load(fromByteOffset: base + offsetNormY, as: Float.self)
            let fA  = raw.load(fromByteOffset: base + offsetA, as: Float.self)
            let fB  = raw.load(fromByteOffset: base + offsetB, as: Float.self)
            let fC  = raw.load(fromByteOffset: base + offsetC, as: Float.self)
            let major = raw.load(fromByteOffset: base + offsetMajor, as: Float.self)
            let minor = raw.load(fromByteOffset: base + offsetMinor, as: Float.self)

            maxA = max(maxA, fA); maxB = max(maxB, fB); maxC = max(maxC, fC)
            maxMajor = max(maxMajor, major); maxMinor = max(maxMinor, minor)

            // 实时曲线：单指时打印诊断字段变化（限流：变化 > 0.01 才打）
            if numTouches == 1, abs(fA - lastLiveA) > 0.01 || abs(fB - lastLiveB) > 0.01 {
                print(String(format: "   t+%.3fs  fA=%.4f  fB=%.4f  fC=%.4f  major=%.3f  (x=%.2f y=%.2f id=%d)",
                             timestamp - sessionStart!, fA, fB, fC, major, x, y, fid))
                lastLiveA = fA; lastLiveB = fB
            }
        }
    }
}

let probe = Probe()

// MARK: - Mouse event tap (NSEvent pressure of real/synthetic clicks)

func installEventTap() -> Bool {
    let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                      options: .listenOnly, eventsOfInterest: mask,
                                      callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
        switch type {
        case .leftMouseDown:
            let p = event.getDoubleValueField(.mouseEventPressure)
            let cs = event.getIntegerValueField(.mouseEventClickState)
            print(String(format: "[DOWN] evPressure=%.3f clickState=%lld", p, cs))
        case .leftMouseUp:
            let p = event.getDoubleValueField(.mouseEventPressure)
            print(String(format: "[UP  ] evPressure=%.3f", p))
        default: break
        }
        return Unmanaged.passUnretained(event)
    }, userInfo: nil) else {
        return false
    }
    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

// MARK: - Main

setbuf(stdout, nil)  // unbuffered — live curves must appear immediately
print("== PressureProbe ==")
guard multitouchFramework != nil else {
    print("ERROR: MultitouchSupport.framework 加载失败"); exit(1)
}

private let createList = unsafeBitCast(dlsym(multitouchFramework, "MTDeviceCreateList")!, to: MTDeviceCreateListFunc.self)
private let registerCb = unsafeBitCast(dlsym(multitouchFramework, "MTRegisterContactFrameCallback")!, to: MTRegisterContactFrameCallbackFunc.self)
private let startDev = unsafeBitCast(dlsym(multitouchFramework, "MTDeviceStart")!, to: MTDeviceStartFunc.self)

let callback: @convention(c) (MTDeviceRef?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Void = { _, touches, n, ts, _ in
    probe.handleFrame(rawTouches: touches, numTouches: Int(n), timestamp: ts)
}

let cfArray = createList().takeRetainedValue()
let count = CFArrayGetCount(cfArray)
print("设备数量: \(count)")
guard count > 0 else { exit(1) }
for i in 0..<count {
    guard let dev = CFArrayGetValueAtIndex(cfArray, i) else { continue }
    let ref = UnsafeMutableRawPointer(mutating: dev)
    registerCb(ref, callback)
    startDev(ref, 0)
}

if installEventTap() {
    print("鼠标事件监听: 已启用（evPressure 可用）")
} else {
    print("鼠标事件监听: 不可用（终端缺少辅助功能权限）— 触控数据仍然有效")
}

print("""
------------------------------------------------------------
开始测试：
  1) 轻点触控板 3 次（不要按下去）
  2) 用力按触控板 3 次（听到/感到 click）
对比 [DOWN] 行的 evPressure 和 SESSION 的 max fA/fB ——
哪个值能区分 tap 和 click，就是我们要的门控信号。Ctrl+C 退出。
------------------------------------------------------------
""")

CFRunLoopRun()
