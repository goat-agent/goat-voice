import Foundation
import GoatVoicePlatform

let core = ServiceCore(provider: ServiceBackend.makeProvider())
let delegate = ServiceListenerDelegate(core: core)
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
ServiceLog.lifecycle.info("stt service listener resumed")
dispatchMain()
