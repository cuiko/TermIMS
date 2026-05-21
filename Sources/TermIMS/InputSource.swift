import Cocoa
import Carbon

struct IMSource {
    let id: String
    let name: String
}

func listInputSources() -> [IMSource] {
    guard let all = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return [] }
    return all.compactMap { tis -> IMSource? in
        guard let typePtr = TISGetInputSourceProperty(tis, kTISPropertyInputSourceType),
              let capPtr  = TISGetInputSourceProperty(tis, kTISPropertyInputSourceIsSelectCapable),
              let enPtr   = TISGetInputSourceProperty(tis, kTISPropertyInputSourceIsEnabled),
              let idPtr   = TISGetInputSourceProperty(tis, kTISPropertyInputSourceID),
              let namePtr = TISGetInputSourceProperty(tis, kTISPropertyLocalizedName) else { return nil }
        let type = Unmanaged<CFString>.fromOpaque(typePtr).takeUnretainedValue() as String
        guard type == kTISTypeKeyboardLayout as String ||
              type == kTISTypeKeyboardInputMode as String else { return nil }
        guard CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(capPtr).takeUnretainedValue()),
              CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(enPtr).takeUnretainedValue()) else { return nil }
        return IMSource(
            id:   Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String,
            name: Unmanaged<CFString>.fromOpaque(namePtr).takeUnretainedValue() as String
        )
    }
}

func currentInputSourceName() -> String? {
    guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
          let ptr = TISGetInputSourceProperty(cur, kTISPropertyLocalizedName) else { return nil }
    return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
}

func selectInputSource(_ id: String) {
    if let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
       let ptr = TISGetInputSourceProperty(cur, kTISPropertyInputSourceID) {
        let curID = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        if curID == id { return }
    }
    let props = [kTISPropertyInputSourceID: id] as CFDictionary
    guard let list = TISCreateInputSourceList(props, false)?.takeRetainedValue() as? [TISInputSource],
          let source = list.first else { return }
    TISSelectInputSource(source)
    NotificationCenter.default.post(name: .imDidSwitch, object: nil)
}
