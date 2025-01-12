import Cocoa
import os

class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let statusIndicator = NSMenuItem(title: "Starting", action: nil, keyEquivalent: "")
    
    var syncTimer: Timer?
    
    var lastBrightness: Double?
    
    // CoreDisplay_Display_GetUserBrightness reports 1.0 for builtin display just before applicationDidChangeScreenParameters when closing lid.
    // This is a workaround to restore the last sane value after syncing stops.
    var lastSaneBrightness: Double?
    var lastSaneBrightnessDelayTimer: Timer?
    
    static let maxDisplays: UInt32 = 8
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        if let button = statusItem.button {
            button.image = #imageLiteral(resourceName: "StatusBarButtonImage")
        }
        
        let menu = NSMenu()
        menu.addItem(statusIndicator)
        menu.addItem(NSMenuItem.separator())
        
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
        menu.addItem(NSMenuItem(title: "v\(appVersion)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Check For Updates", action: #selector(checkForUpdates), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        
        let copyDiagnosticsButton = NSMenuItem(title: "Copy Diagnostics", action: #selector(copyDiagnosticsToPasteboard), keyEquivalent: "c")
        copyDiagnosticsButton.isHidden = true
        copyDiagnosticsButton.allowsKeyEquivalentWhenHidden = true
        menu.addItem(copyDiagnosticsButton)
        
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate), keyEquivalent: ""))
        statusItem.menu = menu
        
        refresh()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
    
    func applicationDidChangeScreenParameters(_ notification: Notification) {
        refresh()
    }
    
    func refresh() {
        os_log("Starting display refresh...")
        
        let allDisplays = AppDelegate.getAllDisplays()
        let lgDisplayIdentifiers = AppDelegate.getConnectedUltraFineDisplayIdentifiers()
        
        let builtin = allDisplays.first { CGDisplayIsBuiltin($0) == 1 }
        let syncTo = allDisplays.filter { lgDisplayIdentifiers.contains(DisplayIdentifier(vendorNumber: CGDisplayVendorNumber($0), modelNumber: CGDisplayModelNumber($0))) }
        
        syncTimer?.invalidate()
        
        if let syncFrom = builtin, !syncTo.isEmpty {
            syncTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { (_) -> Void in
                let newBrightness = CoreDisplay_Display_GetUserBrightness(syncFrom)
                
                if let oldBrightness = self.lastBrightness, abs(oldBrightness - newBrightness) < 0.01 {
                    return
                }
                
                for display in syncTo {
                    CoreDisplay_Display_SetUserBrightness(display, newBrightness)
                }
                
                self.lastBrightness = newBrightness
                
                if newBrightness == 1, self.lastSaneBrightness != 1 {
                    let timerAlreadyRunning = self.lastSaneBrightnessDelayTimer?.isValid ?? false
                    
                    if !timerAlreadyRunning {
                        self.lastSaneBrightnessDelayTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { (_) -> Void in
                            self.lastSaneBrightness = newBrightness
                        }
                    }
                }
                else {
                    self.lastSaneBrightnessDelayTimer?.invalidate()
                    self.lastSaneBrightness = newBrightness
                }
            }
            
            statusIndicator.title = "Activated"
            os_log("Activated...")
        }
        else {
            lastSaneBrightnessDelayTimer?.invalidate()
            if let restoreValue = lastSaneBrightness {
                for display in syncTo {
                    CoreDisplay_Display_SetUserBrightness(display, restoreValue)
                }
                lastSaneBrightness = nil
            }
            
            statusIndicator.title = "Deactivated"
            os_log("Deactivated...")
        }
    }
    
    static func getAllDisplays() -> [CGDirectDisplayID] {
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        var displayCount: UInt32 = 0
        
        CGGetOnlineDisplayList(maxDisplays, &onlineDisplays, &displayCount)
        
        return Array(onlineDisplays[0..<Int(displayCount)])
    }
    
    static func getConnectedUltraFineDisplayIdentifiers() -> Set<DisplayIdentifier> {
        var ultraFineDisplays = Set<DisplayIdentifier>()
        
        for displayInfo in getDisplayInfoDictionaries() {
            if
                let displayNames = displayInfo[kDisplayProductName] as? NSDictionary,
                let displayName = displayNames["en_US"] as? NSString
            {
                if
                    displayName.contains("LG UltraFine"),
                    let vendorNumber = displayInfo[kDisplayVendorID] as? UInt32,
                    let modelNumber = displayInfo[kDisplayProductID] as? UInt32
                {
                    os_log("Found compatible display: %{public}@", displayName)
                    ultraFineDisplays.insert(DisplayIdentifier(vendorNumber: vendorNumber, modelNumber: modelNumber))
                }
                else {
                    os_log("Found incompatible display: %{public}@", displayName)
                }
            }
            else {
                os_log("Display without en_US name found.")
            }
        }
        
        return ultraFineDisplays
    }
    
    static func getDisplayInfoDictionaries() -> [NSDictionary] {
        var diplayInfoDictionaries = [NSDictionary]()
        
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMasterPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == 0 else {
            return diplayInfoDictionaries
        }
        
        var display = IOIteratorNext(iterator)
        
        while display != 0 {
            if let displayInfo = IODisplayCreateInfoDictionary(display, 0)?.takeRetainedValue() as NSDictionary? {
                diplayInfoDictionaries.append(displayInfo)
            }
            
            IOObjectRelease(display)
            
            display = IOIteratorNext(iterator)
        }
        
        IOObjectRelease(iterator)
        
        return diplayInfoDictionaries
    }
    
    @objc func copyDiagnosticsToPasteboard() {
        let CGDisplays = AppDelegate.getAllDisplays()
        let IODisplays = AppDelegate.getDisplayInfoDictionaries()
        
        let diagnostics = """
        CGDisplayList:
        \(CGDisplays.map {
        ["VendorNumber": CGDisplayVendorNumber($0),
        "ModelNumber": CGDisplayModelNumber($0),
        "SerialNumber": CGDisplaySerialNumber($0)]
        })
        
        IODisplayList:
        \(IODisplays)
        """
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnostics, forType: .string)
    }
    
    @objc func checkForUpdates() {
        NSWorkspace.shared.open(URL(string: "https://github.com/OCJvanDijk/Brightness-Sync/releases")!)
    }
    
    struct DisplayIdentifier: Hashable {
        let vendorNumber: UInt32
        let modelNumber: UInt32
    }
}
