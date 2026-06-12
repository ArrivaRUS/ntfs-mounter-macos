// NTFSMounter — menu-bar утилита для управления NTFS-дисками на macOS.
// Показывает иконку диска в статус-баре; в меню — список NTFS-разделов
// (Read/Write через ntfs-3g или Read-Only Apple-драйвер) с кнопками Eject.
//
// Меню перестраивается в момент открытия (NSMenuDelegate.menuNeedsUpdate),
// фонового поллинга нет. Данные берутся из `ntfs-mount list --porcelain`
// (машинный формат device|label|fs|mountpoint|state — устойчив к пробелам
// в метках томов).
//
// Сборка: см. install-gui.sh

import Cocoa

struct NTFSDisk {
    let device: String       // disk5s2
    let label: String        // SKov_usb_ssd
    let mountPoint: String   // /Volumes/SKov_usb_ssd
    let isReadWrite: Bool
    let isMounted: Bool
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    let ntfsMountBin = "/usr/local/bin/ntfs-mount"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "NTFS")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageOnly
        }
        menu.delegate = self
        statusItem.menu = menu
    }

    // Вызывается системой каждый раз перед показом меню — свежие данные
    // ровно тогда, когда они нужны, без фонового таймера.
    func menuNeedsUpdate(_ menu: NSMenu) {
        populate(menu)
    }

    // MARK: - Disk discovery

    func listDisks() -> [NTFSDisk] {
        guard FileManager.default.isExecutableFile(atPath: ntfsMountBin) else { return [] }
        let raw = runShell(ntfsMountBin, args: ["list", "--porcelain"]) ?? ""

        var disks: [NTFSDisk] = []
        for line in raw.split(separator: "\n") {
            // device|label|fs|mountpoint|state
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, f[0].hasPrefix("disk") else { continue }
            let state = f[4].trimmingCharacters(in: .whitespaces)
            let mountPoint = f[3]
            disks.append(NTFSDisk(
                device: f[0],
                label: f[1],
                mountPoint: mountPoint,
                isReadWrite: state == "RW",
                isMounted: !mountPoint.isEmpty && !state.isEmpty
            ))
        }
        return disks
    }

    // MARK: - Menu

    func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let disks = listDisks()

        if disks.isEmpty {
            let item = NSMenuItem(title: "NTFS-диски не подключены", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            for disk in disks {
                addDiskSection(to: menu, disk: disk)
            }
            menu.addItem(.separator())
            let ejectAll = NSMenuItem(title: "Eject All NTFS", action: #selector(ejectAll), keyEquivalent: "e")
            ejectAll.target = self
            menu.addItem(ejectAll)
        }

        menu.addItem(.separator())
        let logs = NSMenuItem(title: "Open Automount Log", action: #selector(openLog), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)

        let quit = NSMenuItem(title: "Quit NTFS Mounter", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    func addDiskSection(to menu: NSMenu, disk: NTFSDisk) {
        let modeTag: String
        if disk.isReadWrite { modeTag = "● RW" }
        else if disk.isMounted { modeTag = "○ RO" }
        else { modeTag = "— not mounted" }

        let header = NSMenuItem(title: "\(disk.label)   \(modeTag)", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let devItem = NSMenuItem(title: "    /dev/\(disk.device)", action: nil, keyEquivalent: "")
        devItem.isEnabled = false
        menu.addItem(devItem)

        if disk.isMounted {
            let mp = NSMenuItem(title: "    Open in Finder", action: #selector(openInFinder(_:)), keyEquivalent: "")
            mp.target = self
            mp.representedObject = disk.mountPoint
            menu.addItem(mp)
        }

        if !disk.isReadWrite {
            let mountAction = NSMenuItem(title: "    Remount as Read/Write", action: #selector(remount(_:)), keyEquivalent: "")
            mountAction.target = self
            mountAction.representedObject = disk.device
            menu.addItem(mountAction)
        }

        let eject = NSMenuItem(title: "    Eject", action: #selector(ejectOne(_:)), keyEquivalent: "")
        eject.target = self
        eject.representedObject = disk.device
        menu.addItem(eject)

        menu.addItem(.separator())
    }

    // MARK: - Actions

    @objc func quit() { NSApp.terminate(nil) }

    @objc func openLog() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/var/log/ntfs-automount.log"))
    }

    @objc func openInFinder(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc func remount(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? String else { return }
        runPrivileged(args: ["mount", device],
                      prompt: "Перемонтировать \(device) в режиме чтения-записи")
    }

    @objc func ejectOne(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? String else { return }
        runPrivileged(args: ["eject", device], prompt: "Eject \(device)")
    }

    @objc func ejectAll() {
        for disk in listDisks() {
            runPrivileged(args: ["eject", disk.device], prompt: "Eject \(disk.device)")
        }
    }

    // MARK: - Privileged execution

    // Запускает `ntfs-mount <args>` с привилегиями. Сначала тихо через
    // `sudo -n` (работает без UI, если install-gui.sh добавил sudoers-правило
    // NOPASSWD); если sudo требует пароль -- стандартный macOS admin-prompt.
    func runPrivileged(args: [String], prompt: String) {
        let p = Process()
        p.launchPath = "/usr/bin/sudo"
        p.arguments = ["-n", ntfsMountBin] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return }
        p.waitUntilExit()

        if p.terminationStatus == 0 { return }

        runWithAdminPrompt(
            message: prompt,
            shell: "\(ntfsMountBin) " + args.joined(separator: " ")
        )
    }

    // MARK: - Shell helpers

    @discardableResult
    func runShell(_ binary: String, args: [String]) -> String? {
        let proc = Process()
        proc.launchPath = binary
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    // Эскалация привилегий через стандартный macOS auth prompt
    func runWithAdminPrompt(message: String, shell: String) {
        let script = """
        do shell script "\(shell.replacingOccurrences(of: "\"", with: "\\\""))" \
            with prompt "\(message)" with administrator privileges
        """
        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        try? task.run()
        task.waitUntilExit()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
