//
//  ScrollPoster.swift
//  Mos
//
//  Created by Caldis on 2020/12/3.
//  Copyright © 2020 Caldis. All rights reserved.
//

import Cocoa
import os

class ScrollPoster {

    // 单例
    static let shared = ScrollPoster()
    init() { NSLog("Module initialized: ScrollPoster") }

    // 插值器
    private let filter = ScrollFilter()
    // 发送器
    private var poster: CVDisplayLink?
    // 滚动数据
    private var current = (y: 0.0, x: 0.0)  // 当前滚动距离
    private var delta = (y: 0.0, x: 0.0)  // 滚动方向记录
    private var buffer = (y: 0.0, x: 0.0)  // 滚动缓冲距离
    // 滚动配置
    private var shifting = false
    private var duration = Options.shared.scrollAdvanced.durationTransition
    // 状态锁: 滚动数据由主线程 (EventTap 回调) 写入, 由 CVDisplayLink 线程读取
    private let stateLock = UnfairLock()
    // 投递上下文: 取代原先跨帧持有的 (event, proxy)
    private let dispatchContext = ScrollDispatchContext.shared
}

// MARK: - 滚动数据更新控制
extension ScrollPoster {
    func update(event: CGEvent, duration: Double, y: Double, x: Double, speed: Double, amplification: Double = 1) -> Self {
        // 更新依赖数据
        // 立即复制事件作为模板, 不在 EventTapCallback 之外持有回调中的 event 和 proxy
        guard dispatchContext.capture(event: event, targetingChrome: ScrollUtils.shared.isEventTargetingChrome(event)) else {
            return self
        }
        stateLock.lock()
        defer { stateLock.unlock() }
        // 更新滚动配置
        self.duration = duration
        // 更新滚动数据
        if y*delta.y > 0 {
            buffer.y += y * speed * amplification
        } else {
            buffer.y = y * speed * amplification
            current.y = 0.0
        }
        if x*delta.x > 0 {
            buffer.x += x * speed * amplification
        } else {
            buffer.x = x * speed * amplification
            current.x = 0.0
        }
        delta = (y: y, x: x)
        return self
    }
    func updateShifting(enable: Bool) {
        stateLock.lock()
        shifting = enable
        stateLock.unlock()
    }
    func shift(with nextValue: ( y: Double, x: Double )) -> (y: Double, x: Double) {
        // 如果按下 Shift, 则始终将滚动转为横向
        if shifting {
            // 判断哪个轴有值, 有值则赋给 X
            // 某些鼠标 (MXMaster/MXAnywhere), 按下 Shift 后会显式转换方向为横向, 此处针对这类转换进行归一化处理
            if nextValue.y != 0.0 && nextValue.x == 0.0 {
                return (y: nextValue.x, x: nextValue.y)
            } else {
                return (y: nextValue.y, x: nextValue.x)
            }
        } else {
            return (y: nextValue.y, x: nextValue.x)
        }
    }
    func brake() {
        stateLock.lock()
        buffer = current
        stateLock.unlock()
    }
    func reset() {
        // 使所有尚未投递的帧失效
        dispatchContext.invalidateAll()
        stateLock.lock()
        resetUnlocked()
        stateLock.unlock()
    }
    private func resetUnlocked() {
        // 重置数值
        dispatchContext.clearContext()
        current = ( y: 0.0, x: 0.0 )
        delta = ( y: 0.0, x: 0.0 )
        buffer = ( y: 0.0, x: 0.0 )
        // 重置插值器
        filter.reset()
    }
}

// MARK: - 插值数据发送控制
extension ScrollPoster {
    // 初始化 CVDisplayLink
    func create() {
        // 新建一个 CVDisplayLinkSetOutputCallback 来执行循环
        CVDisplayLinkCreateWithActiveCGDisplays(&poster)
        if let validPoster = poster {
            CVDisplayLinkSetOutputCallback(validPoster, { (displayLink, inNow, inOutputTime, flagsIn, flagsOut, displayLinkContext) -> CVReturn in
                ScrollPoster.shared.processing()
                return kCVReturnSuccess
            }, nil)
        }
    }
    // 启动事件发送器
    func tryStart() {
        if let validPoster = poster {
            if !CVDisplayLinkIsRunning(validPoster) {
                CVDisplayLinkStart(validPoster)
            }
        }
    }
    // 停止事件发送器
    func stop(_ phase: Phase = Phase.PauseManual) {
        // 停止循环
        if let validPoster = poster {
            CVDisplayLinkStop(validPoster)
        }
        // 丢弃已排队但尚未投递的旧帧, 下面的收尾帧使用新代次
        dispatchContext.advanceGeneration()
        stateLock.lock()
        // 先设置阶段为停止
        ScrollPhase.shared.stop(phase)
        // 对于 Phase.PauseAuto, 我们在结束前额外发送一个事件来重置 Chrome 的滚动缓冲区
        if let snapshot = dispatchContext.preparePostingSnapshot(), snapshot.targetingChrome {
            // 需要附加特定的阶段数据, 只有 Phase.PauseManual 对应的 [4.0, 0.0] 可以正确使 Chrome 恢复
            snapshot.event.setDoubleValueField(.scrollWheelEventScrollPhase, value: PhaseValueMapping[Phase.PauseManual]![PhaseItem.Scroll]!)
            snapshot.event.setDoubleValueField(.scrollWheelEventMomentumPhase, value: PhaseValueMapping[Phase.PauseManual]![PhaseItem.Momentum]!)
            post(snapshot, (y: 0.0, x: 0.0))
        }
        // 重置参数 (不递增代次, 保留收尾帧)
        resetUnlocked()
        stateLock.unlock()
    }
}

// MARK: - 数据处理及发送
private extension ScrollPoster {
    // 处理滚动事件
    func processing() {
        stateLock.lock()
        // 计算插值
        let frame = (
            y: Interpolator.lerp(src: current.y, dest: buffer.y, trans: duration),
            x: Interpolator.lerp(src: current.x, dest: buffer.x, trans: duration)
        )
        // 更新滚动位置
        current = (
            y: current.y + frame.y,
            x: current.x + frame.x
        )
        // 平滑滚动结果
        let filledValue = filter.fill(with: frame)
        // 变换滚动结果
        let shiftedValue = shift(with: filledValue)
        // 发送滚动结果
        if let snapshot = dispatchContext.preparePostingSnapshot() {
            post(snapshot, shiftedValue)
        }
        stateLock.unlock()
        // 如果临近目标距离小于精确度门限则暂停滚动 (stop 需要自行加锁, 因此在解锁后调用)
        if (
            frame.y.magnitude <= Options.shared.scrollAdvanced.precision &&
            frame.x.magnitude <= Options.shared.scrollAdvanced.precision
        ) {
            stop(Phase.PauseAuto)
        }
    }
    func post(_ snapshot: ScrollDispatchContext.PostingSnapshot, _ v: (y: Double, x: Double)) {
        // 设置阶段数据
        ScrollPhase.shared.transfrom()
        // 设置滚动数据
        snapshot.event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: v.y)
        snapshot.event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: v.x)
        snapshot.event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0.0)
        snapshot.event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 0.0)
        snapshot.event.setDoubleValueField(.scrollWheelEventIsContinuous, value: 1.0)
        // 标记为 Mos 合成的事件, 万一重新进入 EventTap 时直接放行
        ScrollUtils.shared.markSyntheticSmoothEvent(snapshot.event)
        // 原先使用 tapPostEvent(proxy) 在 CVDisplayLink 线程上投递, 但 proxy 只在 EventTapCallback 执行期间有效
        // 跨帧持有并在其他线程使用会破坏 SkyLight 的内部状态, 导致主线程在 processEventTapData 中崩溃
        // 现改为直接投递到原事件的目标进程, 不再依赖 proxy (同上游 4.0.2 的修复, issue #868)
        dispatchContext.enqueue(snapshot)
    }
}

// MARK: - 投递上下文
// 移植自上游 4.0.2 的 ScrollDispatchContext, 去掉了 TTL 与调试计数, 以保持 3.5.0 的滚动行为不变
final class ScrollDispatchContext {

    // 单例
    static let shared = ScrollDispatchContext()
    private init() {}

    struct PostingSnapshot {
        let event: CGEvent
        let targetPID: pid_t
        let targetingChrome: Bool
        let generation: UInt64
    }

    private let lock = UnfairLock()
    private var eventTemplate: CGEvent?
    private var targetPID: pid_t = 0
    private var targetingChrome = false
    private var generation: UInt64 = 0
    // 串行队列, 保证帧按顺序投递
    private let postQueue = DispatchQueue(label: "com.caldis.Mos.scrollposter.post", qos: .userInteractive)

    // 在 EventTapCallback 内调用: 复制事件并记录目标进程
    func capture(event: CGEvent, targetingChrome: Bool) -> Bool {
        guard let template = event.copy() else {
            return false
        }
        let pid = pid_t(event.getIntegerValueField(.eventTargetUnixProcessID))
        lock.lock()
        eventTemplate = template
        targetPID = pid
        self.targetingChrome = targetingChrome
        lock.unlock()
        return true
    }
    func advanceGeneration() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }
    func clearContext() {
        lock.lock()
        eventTemplate = nil
        targetPID = 0
        targetingChrome = false
        lock.unlock()
    }
    func invalidateAll() {
        lock.lock()
        generation &+= 1
        eventTemplate = nil
        targetPID = 0
        targetingChrome = false
        lock.unlock()
    }
    // 每一帧都从模板复制一个新事件
    func preparePostingSnapshot() -> PostingSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let eventClone = eventTemplate?.copy() else {
            return nil
        }
        return PostingSnapshot(event: eventClone, targetPID: targetPID, targetingChrome: targetingChrome, generation: generation)
    }
    func enqueue(_ snapshot: PostingSnapshot) {
        postQueue.async { [self] in
            // 停止或重置后, 丢弃旧代次的帧
            lock.lock()
            let valid = snapshot.generation == generation
            lock.unlock()
            guard valid else { return }
            if snapshot.targetPID > 1 {
                // 直接投递到目标进程, 惯性阶段光标移到其他窗口时滚动仍留在原目标
                snapshot.event.postToPid(snapshot.targetPID)
            } else {
                // 目标进程未知时, 交给系统按位置路由 (合成标记保证不会被 Mos 重复处理)
                snapshot.event.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }
}

// MARK: - 锁
// os_unfair_lock 需要固定的内存地址, 因此单独分配
final class UnfairLock {
    private let pointer: UnsafeMutablePointer<os_unfair_lock>
    init() {
        pointer = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        pointer.initialize(to: os_unfair_lock())
    }
    deinit {
        pointer.deinitialize(count: 1)
        pointer.deallocate()
    }
    func lock() { os_unfair_lock_lock(pointer) }
    func unlock() { os_unfair_lock_unlock(pointer) }
}
