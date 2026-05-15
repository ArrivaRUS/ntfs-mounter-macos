// NTFSMounter — menu-bar утилита для управления NTFS-дисками на macOS.
// Показывает иконку диска в статус-баре; в меню — список NTFS-разделов
// (Read/Write через ntfs-3g или Read-Only Apple-драйвер) с кнопками Eject.
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var refreshTimer: Timer!
    let ntfsMountBin = "/usr/local/bin/ntfs-mount"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "NTFS")
            img?.isTemplate = true
            button.image = img
            button.imagePosition = .imageOnly
        }

        rebuildMenu()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.rebuildMenu()
        }
    }

    // MARK: - Disk discovery

    func listDisks() -> [NTFSDisk] {
        guard FileManager.default.isExecutableFile(atPath: ntfsMountBin) else { return [] }
        let raw = runShell(ntfsMountBin, args: ["list"]) ?? ""

        var disks: [NTFSDisk] = []
        // Парсим вывод (skip header rows). Формат строки:
        //   DEVICE    LABEL    FS    MOUNT POINT [RO|RW]
        let lines = raw.split(separator: "\n").map(String.init)
        for line in lines {
            if line.hasPrefix("DEVICE") || line.hasPrefix("------") || line.contains("NTFS-разделов") { continue }
            // strip ANSI
            let clean = line.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
            let cols = clean.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard cols.count >= 3 else { continue }
            let device = cols[0]
            let label = cols[1]
            let fs = cols[2]
            guard !fs.lowercased().contains("ntfs") || device.hasPrefix("disk") else { continue }
            let rest = cols.dropFirst(3).joined(separator: " ")
            let isRW = rest.contains("[RW]")
            let isRO = rest.contains("[RO]")
            let mount = rest
                .replacingOccurrences(of: "[RW]", with: "")
                .replacingOccurrences(of: "[RO]", with: "")
                .replacingOccurrences(of: "(не смонтирован)", with: "")
                .trimmingCharacters(in: .whitespaces)
            let isMounted = !mount.isEmpty && (isRW || isRO)
            disks.append(NTFSDisk(
                device: device, label: label,
                mountPoint: mount,
                isReadWrite: isRW,
                isMounted: isMounted
            ))
        }
        return disks
    }

    // MARK: - Menu

    func rebuildMenu() {
        let menu = NSMenu()
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
        let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        menu.addItem(.separator())
        let logs = NSMenuItem(title: "Open Automount Log", action: #selector(openLog), keyEquivalent: "")
        logs.target = self
        menu.addItem(logs)

        let quit = NSMenuItem(title: "Quit NTFS Mounter", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
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

    @objc func refreshNow() { rebuildMenu() }

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
        // ntfs-mount mount требует sudo. У GUI без sudoers это покажет пароль через osascript.
        runWithAdminPrompt(message: "Перемонтировать \(device) в режиме чтения-записи",
                           shell: "\(ntfsMountBin) mount \(device)")
        rebuildMenu()
    }

    @objc func ejectOne(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? String else { return }
        ejectViaUtility(device: device)
        rebuildMenu()
    }

    @objc func ejectAll() {
        for disk in listDisks() {
            ejectViaUtility(device: disk.device)
        }
        rebuildMenu()
    }

    // Вызывает `ntfs-mount eject`. Сначала пробует через sudo -n (если есть
    // sudoers-правило, установленное install-gui.sh) -- работает без UI.
    // Если sudoers не настроен -- fallback на стандартный macOS admin-prompt.
    func ejectViaUtility(device: String) {
        // 1. Попытка без UI через sudo -n
        let p = Process()
        p.launchPath = "/usr/bin/sudo"
        p.arguments = ["-n", ntfsMountBin, "eject", device]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return }
        p.waitUntilExit()

        if p.terminationStatus == 0 { return }

        // 2. Fallback: системный admin-prompt
        runWithAdminPrompt(
            message: "Eject \(device)",
            shell: "\(ntfsMountBin) eject \(device)"
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
