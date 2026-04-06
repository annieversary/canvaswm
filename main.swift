// canvaswm — hold Ctrl+Cmd while dragging a window to move all windows together
// Build: swiftc -framework Cocoa -framework ApplicationServices -o tilewm main.swift

import Cocoa
import ApplicationServices

// Drag state
var dragActive = false
var dragStartMouse = CGPoint.zero
var dragCurrentMouse = CGPoint.zero
var dragPending = false
var draggedElement: AXUIElement? = nil
// Snapshots of non-dragged windows: (element, virtual position at drag start, size)
var snapshots: [(AXUIElement, CGPoint, CGSize)] = []

// Virtual canvas state — persists across drag gestures
var virtualPositions: [CFHashCode: CGPoint] = [:]
var parkedWindows: Set<CFHashCode> = []
var clippedWindows: Set<CFHashCode> = []
var originalSizes: [CFHashCode: CGSize] = [:]
let parkingSpot = CGPoint(x: 100_000, y: 100_000)

func windowsWithPositions() -> [(AXUIElement, CGPoint)] {
    var result: [(AXUIElement, CGPoint)] = []
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

    for app in apps {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
            let windows = ref as? [AXUIElement]
        else { continue }

        for win in windows {
            // Skip minimized
            var minRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef) == .success,
               (minRef as? Bool) == true { continue }

            var posRef: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
                let posVal = posRef
            else { continue }
            var pos = CGPoint.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
            result.append((win, pos))
        }
    }
    return result
}

func focusedElement() -> AXUIElement? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)
    var ref: CFTypeRef?
    guard
        AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &ref) == .success
    else { return nil }
    return (ref as! AXUIElement)
}

func setPosition(_ element: AXUIElement, to point: CGPoint) {
    var p = point
    let val = AXValueCreate(.cgPoint, &p)!
    AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, val)
}

func getSize(_ element: AXUIElement) -> CGSize {
    var ref: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success,
          let val = ref else { return .zero }
    var size = CGSize.zero
    AXValueGetValue(val as! AXValue, .cgSize, &size)
    return size
}

func setSize(_ element: AXUIElement, to size: CGSize) {
    var s = size
    let val = AXValueCreate(.cgSize, &s)!
    AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, val)
}

let titleBarHeight: CGFloat = 28

func isOnScreen(_ pos: CGPoint, size: CGSize) -> Bool {
    let mainH = NSScreen.main!.frame.height
    for screen in NSScreen.screens {
        let vf = screen.frame
        let axTop    = mainH - (vf.origin.y + vf.height)
        let axBottom = mainH - vf.origin.y
        let axLeft   = vf.origin.x
        let axRight  = vf.origin.x + vf.width
        let vertOK  = pos.y >= axTop && pos.y < axBottom
        let horizOK = pos.x < axRight && (pos.x + size.width) > axLeft
        if vertOK && horizOK { return true }
    }
    return false
}

// Returns the visible (pos, size) of a window clipped to the screen it overlaps most,
// or nil if the window is entirely off-screen.
func clippedFrame(virtualPos: CGPoint, size: CGSize) -> (CGPoint, CGSize)? {
    let mainH = NSScreen.main!.frame.height
    var bestArea: CGFloat = 0
    var bestResult: (CGPoint, CGSize)? = nil

    for screen in NSScreen.screens {
        let vf = screen.frame
        let sTop    = mainH - (vf.origin.y + vf.height)
        let sBottom = mainH - vf.origin.y
        let sLeft   = vf.origin.x
        let sRight  = vf.origin.x + vf.width

        // Title bar must be above screen bottom — once it goes below, park instead
        guard virtualPos.y < sBottom else { continue }

        // Horizontal: check overlap but don't clip — macOS handles windows off the sides
        let horizOverlapLeft  = max(virtualPos.x, sLeft)
        let horizOverlapRight = min(virtualPos.x + size.width, sRight)
        guard horizOverlapRight > horizOverlapLeft else { continue }

        // Vertical: clip only the top edge; bottom extends freely
        let clipTop     = max(virtualPos.y, sTop)
        let vertOverlap = min(virtualPos.y + size.height, sBottom) - clipTop
        guard vertOverlap > 0 else { continue }

        let area = (horizOverlapRight - horizOverlapLeft) * vertOverlap
        if area > bestArea {
            bestArea = area
            let retH = (virtualPos.y + size.height) - clipTop
            bestResult = (CGPoint(x: virtualPos.x, y: clipTop), CGSize(width: size.width, height: retH))
        }
    }
    return bestResult
}

func windowsWithFrames() -> [(AXUIElement, CGPoint, CGSize)] {
    var result: [(AXUIElement, CGPoint, CGSize)] = []
    let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }

    for app in apps {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var ref: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &ref) == .success,
            let windows = ref as? [AXUIElement]
        else { continue }

        for win in windows {
            var minRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXMinimizedAttribute as CFString, &minRef) == .success,
               (minRef as? Bool) == true { continue }

            var posRef: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
                let posVal = posRef
            else { continue }
            var pos = CGPoint.zero
            AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)

            let size = getSize(win)
            result.append((win, pos, size))
        }
    }
    return result
}

func setupEventTap() {
    let mask: CGEventMask =
        (1 << CGEventType.leftMouseDown.rawValue)
        | (1 << CGEventType.leftMouseDragged.rawValue)
        | (1 << CGEventType.leftMouseUp.rawValue)
        | (1 << CGEventType.scrollWheel.rawValue)

    guard
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, _ -> Unmanaged<CGEvent>? in
                let cmdOpt: CGEventFlags = [.maskCommand, .maskControl]
                let held = event.flags.intersection(cmdOpt) == cmdOpt

                switch type {
                case .leftMouseDown:
                    if held {
                        dragActive = true
                        dragStartMouse = event.location
                        draggedElement = focusedElement()
                        let currentFrames = windowsWithFrames()
                        snapshots = currentFrames.map { (win, actualPos, size) in
                            let key = CFHash(win)
                            let origSize = originalSizes[key] ?? size
                            if parkedWindows.contains(key) {
                                return (win, virtualPositions[key] ?? actualPos, origSize)
                            } else {
                                virtualPositions[key] = actualPos
                                return (win, actualPos, origSize)
                            }
                        }
                        return nil
                    }

                case .leftMouseDragged:
                    if dragActive && held {
                        dragCurrentMouse = event.location
                        if !dragPending {
                            dragPending = true
                            let current = snapshots
                            let start = dragStartMouse
                            DispatchQueue.main.async {
                                dragPending = false
                                let dx = dragCurrentMouse.x - start.x
                                let dy = dragCurrentMouse.y - start.y
                                for (win, virtualOrigin, size) in current {
                                    let key = CFHash(win)
                                    let newVirtual = CGPoint(x: virtualOrigin.x + dx, y: virtualOrigin.y + dy)
                                    virtualPositions[key] = newVirtual

                                    if let (clippedPos, clippedSize) = clippedFrame(virtualPos: newVirtual, size: size) {
                                        parkedWindows.remove(key)
                                        let needsClip = clippedSize.width < size.width - 0.5
                                                     || clippedSize.height < size.height - 0.5
                                        if needsClip {
                                            if originalSizes[key] == nil { originalSizes[key] = size }
                                            clippedWindows.insert(key)
                                            setSize(win, to: clippedSize)
                                            setPosition(win, to: clippedPos)
                                        } else {
                                            if clippedWindows.remove(key) != nil {
                                                originalSizes.removeValue(forKey: key)
                                                setSize(win, to: size)
                                            }
                                            setPosition(win, to: clippedPos)
                                        }
                                    } else if !parkedWindows.contains(key) {
                                        if clippedWindows.remove(key) != nil {
                                            originalSizes.removeValue(forKey: key)
                                            setSize(win, to: size)
                                        }
                                        parkedWindows.insert(key)
                                        setPosition(win, to: parkingSpot)
                                    }
                                }
                            }
                        }
                        return nil
                    } else if !held {
                        dragActive = false
                    }

                case .leftMouseUp:
                    if dragActive {
                        dragActive = false
                        dragPending = false
                        snapshots = []
                        draggedElement = nil
                        return nil
                    }
                    dragActive = false
                    dragPending = false
                    snapshots = []
                    draggedElement = nil

                case .scrollWheel:
                    if held {
                        let delta = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
                        guard delta != 0 else { break }
                        let scale = 1.0 + delta * 0.05
                        let center = event.location
                        let frames = windowsWithFrames()
                        DispatchQueue.main.async {
                            for (win, pos, size) in frames {
                                if parkedWindows.contains(CFHash(win)) { continue }
                                let newW = max(100, size.width * scale)
                                let newH = max(60, size.height * scale)
                                let newX = center.x + (pos.x - center.x) * scale
                                let newY = center.y + (pos.y - center.y) * scale
                                setSize(win, to: CGSize(width: newW, height: newH))
                                setPosition(win, to: CGPoint(x: newX, y: newY))
                            }
                        }
                        return nil  // swallow so OS doesn't scroll anything
                    }

                default:
                    break
                }

                return Unmanaged.passRetained(event)
            },
            userInfo: nil
        )
    else {
        print("Failed to create event tap — check Accessibility permissions.")
        exit(1)
    }

    let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
}

// Check / prompt for Accessibility permission
let trusted = AXIsProcessTrustedWithOptions(
    [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
if !trusted {
    print("Grant Accessibility access in System Settings → Privacy & Security → Accessibility, then relaunch.")
    exit(1)
}

setupEventTap()
print("Running — hold Ctrl+Cmd while dragging a window to move all windows together.")
NSApplication.shared.run()
