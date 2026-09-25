import AppKit

let app = NSApplication.shared
let router: SingleInstanceRouter
do { router = try SingleInstanceRouter() }
catch { NSAlert(error: error).runModal(); exit(1) }
let delegate = AppDelegate(instanceRouter: router)
app.delegate = delegate
app.setActivationPolicy(router.isPrimary ? .regular : .accessory)
app.run()
