/// FootprintWindow.swift

import Cocoa

class FootprintWindow: NSWindow {
    private var orderOutCanceled = false
    
    init() {
        let initialRect = NSRect(x: 0, y: 0, width: 0, height: 0)
        super.init(contentRect: initialRect, styleMask: .titled, backing: .buffered, defer: false)

        title = "Rectangle"
        isOpaque = false
        level = .modalPanel
        hasShadow = false
        isReleasedWhenClosed = false
        alphaValue = Defaults.footprintFade.userDisabled
            ? CGFloat(Defaults.footprintAlpha.value)
            : 0
  
        styleMask.insert(.fullSizeContentView)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        collectionBehavior.insert(.transient)
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        standardWindowButton(.toolbarButton)?.isHidden = true
        
        let boxView = NSBox()
        boxView.boxType = .custom
        boxView.borderColor = .lightGray
        boxView.borderWidth = CGFloat(Defaults.footprintBorderWidth.value)
        
        if #available(macOS 26.0, *) {
            boxView.cornerRadius = 16
        } else if #available(macOS 11.0, *) {
            boxView.cornerRadius = 10
        } else {
            boxView.cornerRadius = 5
        }
        boxView.wantsLayer = true
        boxView.fillColor = Defaults.footprintColor.typedValue?.nsColor ?? NSColor.black
        contentView = boxView
    }

    
    override var isVisible: Bool {
        // Workaround for footprint getting pushed off of Stage Manager
        if StageUtil.stageCapable && StageUtil.stageEnabled && StageUtil.stageStripShow {
            return true
        }
        return realIsVisible
    }
    
    var realIsVisible: Bool {
        if Defaults.footprintFade.userDisabled {
            return super.isVisible
        } else {
            return alphaValue == Defaults.footprintAlpha.cgFloat
        }
    }
    
    override func orderFront(_ sender: Any?) {
        // Mark any in-flight fade-out as canceled so its completion won't
        // remove the window, and set the alpha immediately (no animation) so
        // the preview shows up right away even mid-fade.
        orderOutCanceled = true
        super.orderFront(sender)
        if !Defaults.footprintFade.userDisabled {
            alphaValue = Defaults.footprintAlpha.cgFloat
        }
    }
    
    override func orderOut(_ sender: Any?) {
        if Defaults.footprintFade.userDisabled {
            super.orderOut(nil)
        } else {
            orderOutCanceled = false
            NSAnimationContext.runAnimationGroup { changes in
                animator().alphaValue = 0.0
            } completionHandler: {
                if self.orderOutCanceled {
                    // The window was re-shown while the fade was running; the
                    // fade animation may have won the race and left alpha at 0,
                    // which would leave an invisible modalPanel-level window
                    // swallowing clicks. Force it back to visible.
                    self.alphaValue = Defaults.footprintAlpha.cgFloat
                } else {
                    super.orderOut(nil)
                }
            }
        }
    }
}
