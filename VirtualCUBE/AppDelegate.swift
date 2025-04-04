import Cocoa
import Virtualization

@main
class AppDelegate: NSObject, NSApplicationDelegate, VZVirtualMachineDelegate {
    
    @IBOutlet var window: NSWindow!
    @IBOutlet weak var virtualMachineView: VZVirtualMachineView!
    
    private var virtualMachine: VZVirtualMachine!
    
    // ISO インストールの場合に使用するパス
    private var installerISOPath: URL?
    
    // VM バンドル関連のパス（全データを永続化）
    let vmBundlePath = NSHomeDirectory() + "/VirtualCUBE/Latest.bundle/"
    let mainDiskImagePath = NSHomeDirectory() + "/VirtualCUBE/Latest.bundle/Disk.img"
    let efiVariableStorePath = NSHomeDirectory() + "/VirtualCUBE/Latest.bundle/NVRAM"
    let machineIdentifierPath = NSHomeDirectory() + "/VirtualCUBE/Latest.bundle/MachineIdentifier"
    
    // ユーザー設定（デフォルト値）
    var memoryCapacityGB: UInt64 = 4     // メモリ (GB)
    var storageCapacityGB: UInt64 = 64   // ストレージ (GB) ※ISO インストールの場合のみ利用
    var userSelectedCPUCores: Int = 2   // CPU コア数 ※ISO インストールの場合のみ利用
    
    // インストール方法
    enum InstallationMethod {
        case iso
        case persistent
    }
    var installationMethod: InstallationMethod = .iso
    
    // NSAlert での「ファイルパス」表示用テキストフィールド（後で値を設定）
    var filePathField: NSTextField!
    
    // Properties to hold references to the CPU and storage text fields
    var cpuField: NSTextField?
    var storageField: NSTextField?
    
    // 毎回設定を入力させるので、常に新規設定とする（永続化の場合は指定ファイルをコピー）
    private var needsInstall = true
    
    // MARK: - VM バンドル・ディスクイメージ作成
    
    private func createVMBundle() {
        do {
            try FileManager.default.createDirectory(atPath: vmBundlePath, withIntermediateDirectories: true)
        } catch {
            fatalError("GUI Linux VM.bundle の作成に失敗しました: \(error)")
        }
    }
    
    // ユーザー指定のストレージ容量で空のディスクイメージを作成（ISO インストール時）
    private func createMainDiskImage() {
        let sizeInBytes = storageCapacityGB * 1024 * 1024 * 1024
        let diskCreated = FileManager.default.createFile(atPath: mainDiskImagePath, contents: nil, attributes: nil)
        if !diskCreated {
            fatalError("メインディスクイメージの作成に失敗しました。")
        }
        guard let mainDiskFileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: mainDiskImagePath)) else {
            fatalError("メインディスクイメージのファイルハンドル取得に失敗しました。")
        }
        do {
            try mainDiskFileHandle.truncate(atOffset: sizeInBytes)
        } catch {
            fatalError("メインディスクイメージのトランケートに失敗しました: \(error)")
        }
    }
    
    // MARK: - デバイス設定
    
    private func createBlockDeviceConfiguration() -> VZVirtioBlockDeviceConfiguration {
        guard let mainDiskAttachment = try? VZDiskImageStorageDeviceAttachment(url: URL(fileURLWithPath: mainDiskImagePath), readOnly: false) else {
            fatalError("メインディスクのアタッチメント作成に失敗しました。")
        }
        let mainDisk = VZVirtioBlockDeviceConfiguration(attachment: mainDiskAttachment)
        return mainDisk
    }
    
    // ユーザー指定のメモリ容量 (GB) をバイトに変換
    private func computeMemorySize() -> UInt64 {
        let userMemory = memoryCapacityGB * 1024 * 1024 * 1024
        var memorySize = userMemory
        memorySize = max(memorySize, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        memorySize = min(memorySize, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        return memorySize
    }
    
    // CPU コア数（ISO インストールの場合はユーザー入力、永続化の場合はシステムに合わせる）
    private func computeCPUCount() -> Int {
        if installationMethod == .iso {
            return max(1, userSelectedCPUCores)
        } else {
            let totalAvailableCPUs = ProcessInfo.processInfo.processorCount
            var virtualCPUCount = totalAvailableCPUs <= 1 ? 1 : totalAvailableCPUs - 1
            virtualCPUCount = max(virtualCPUCount, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
            virtualCPUCount = min(virtualCPUCount, VZVirtualMachineConfiguration.maximumAllowedCPUCount)
            return virtualCPUCount
        }
    }
    
    private func createAndSaveMachineIdentifier() -> VZGenericMachineIdentifier {
        let machineIdentifier = VZGenericMachineIdentifier()
        try! machineIdentifier.dataRepresentation.write(to: URL(fileURLWithPath: machineIdentifierPath))
        return machineIdentifier
    }
    
    private func retrieveMachineIdentifier() -> VZGenericMachineIdentifier {
        guard let machineIdentifierData = try? Data(contentsOf: URL(fileURLWithPath: machineIdentifierPath)) else {
            fatalError("Machine identifier データの取得に失敗しました。")
        }
        guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: machineIdentifierData) else {
            fatalError("Machine identifier の生成に失敗しました。")
        }
        return machineIdentifier
    }
    
    private func createEFIVariableStore() -> VZEFIVariableStore {
        guard let efiVariableStore = try? VZEFIVariableStore(creatingVariableStoreAt: URL(fileURLWithPath: efiVariableStorePath)) else {
            fatalError("Failed for Create EFI Variable Store. The file may already exist in '/Users/diamondgotcat/VirtualCUBE/latest.bundle'")
        }
        return efiVariableStore
    }
    
    private func retrieveEFIVariableStore() -> VZEFIVariableStore {
        if !FileManager.default.fileExists(atPath: efiVariableStorePath) {
            fatalError("Create EFI Variable Store Not Found.")
        }
        return VZEFIVariableStore(url: URL(fileURLWithPath: efiVariableStorePath))
    }
    
    private func createUSBMassStorageDeviceConfiguration() -> VZUSBMassStorageDeviceConfiguration {
        // installerISOPath が正しく設定されているかをチェック
        guard let installerISOPath = installerISOPath else {
            fatalError("Internal Error: Nil Setted; installerISOPath")
        }
        // デバッグ用ログ
        print("installerISOPath: \(installerISOPath)")
        
        // ISO のアタッチメント生成を試みる
        guard let isoAttachment = try? VZDiskImageStorageDeviceAttachment(url: installerISOPath, readOnly: false) else {
            fatalError("Failed to create disk attachment for ISO. Is this Not ISO File?")
        }
        return VZUSBMassStorageDeviceConfiguration(attachment: isoAttachment)
    }
    
    private func createNetworkDeviceConfiguration() -> VZVirtioNetworkDeviceConfiguration {
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        return networkDevice
    }
    
    private func createGraphicsDeviceConfiguration() -> VZVirtioGraphicsDeviceConfiguration {
        let graphicsDevice = VZVirtioGraphicsDeviceConfiguration()
        graphicsDevice.scanouts = [VZVirtioGraphicsScanoutConfiguration(widthInPixels: 1280, heightInPixels: 720)]
        return graphicsDevice
    }
    
    private func createInputAudioDeviceConfiguration() -> VZVirtioSoundDeviceConfiguration {
        let inputAudioDevice = VZVirtioSoundDeviceConfiguration()
        let inputStream = VZVirtioSoundDeviceInputStreamConfiguration()
        inputStream.source = VZHostAudioInputStreamSource()
        inputAudioDevice.streams = [inputStream]
        return inputAudioDevice
    }
    
    private func createOutputAudioDeviceConfiguration() -> VZVirtioSoundDeviceConfiguration {
        let outputAudioDevice = VZVirtioSoundDeviceConfiguration()
        let outputStream = VZVirtioSoundDeviceOutputStreamConfiguration()
        outputStream.sink = VZHostAudioOutputStreamSink()
        outputAudioDevice.streams = [outputStream]
        return outputAudioDevice
    }
    
    private func createSpiceAgentConsoleDeviceConfiguration() -> VZVirtioConsoleDeviceConfiguration {
        let consoleDevice = VZVirtioConsoleDeviceConfiguration()
        let spiceAgentPort = VZVirtioConsolePortConfiguration()
        spiceAgentPort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        spiceAgentPort.attachment = VZSpiceAgentPortAttachment()
        consoleDevice.ports[0] = spiceAgentPort
        return consoleDevice
    }
    
    // MARK: - 仮想マシン設定と起動
    
    func createVirtualMachine() {
        let virtualMachineConfiguration = VZVirtualMachineConfiguration()
        virtualMachineConfiguration.cpuCount = computeCPUCount()
        virtualMachineConfiguration.memorySize = computeMemorySize()
        
        let platform = VZGenericPlatformConfiguration()
        let bootloader = VZEFIBootLoader()
        let disksArray = NSMutableArray()
        
        if needsInstall {
            // 新規インストールの場合（ISO インストール）
            platform.machineIdentifier = createAndSaveMachineIdentifier()
            bootloader.variableStore = createEFIVariableStore()
            // ISO を USB マスストレージ経由で接続
            disksArray.add(createUSBMassStorageDeviceConfiguration())
        } else {
            // 永続化ファイルの場合
            platform.machineIdentifier = retrieveMachineIdentifier()
            bootloader.variableStore = retrieveEFIVariableStore()
        }
        
        virtualMachineConfiguration.platform = platform
        virtualMachineConfiguration.bootLoader = bootloader
        
        disksArray.add(createBlockDeviceConfiguration())
        guard let disks = disksArray as? [VZStorageDeviceConfiguration] else {
            fatalError("ディスク設定が無効です。")
        }
        virtualMachineConfiguration.storageDevices = disks
        
        virtualMachineConfiguration.networkDevices = [createNetworkDeviceConfiguration()]
        virtualMachineConfiguration.graphicsDevices = [createGraphicsDeviceConfiguration()]
        virtualMachineConfiguration.audioDevices = [createInputAudioDeviceConfiguration(), createOutputAudioDeviceConfiguration()]
        
        virtualMachineConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
        virtualMachineConfiguration.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]
        virtualMachineConfiguration.consoleDevices = [createSpiceAgentConsoleDeviceConfiguration()]
        
        do {
            try virtualMachineConfiguration.validate()
        } catch {
            fatalError("VM 設定の検証に失敗しました: \(error)")
        }
        virtualMachine = VZVirtualMachine(configuration: virtualMachineConfiguration)
    }
    
    func configureAndStartVirtualMachine() {
        DispatchQueue.main.async {
            self.createVirtualMachine()
            self.virtualMachineView.virtualMachine = self.virtualMachine
            
            if #available(macOS 14.0, *) {
                self.virtualMachineView.automaticallyReconfiguresDisplay = true
            }
            
            self.virtualMachine.delegate = self
            self.virtualMachine.start { result in
                switch result {
                case let .failure(error):
                    self.presentErrorAlert(message: "仮想マシンの起動に失敗しました: \(error)")
                case .success:
                    print("仮想マシンが正常に起動しました。")
                }
            }
        }
    }
    
    // MARK: - ユーザー入力プロンプト
    
    /// アプリ起動後に毎回、インストール方法、ファイルの場所、メモリ、およびISOの場合はCPUコア数とストレージ容量を問い合わせる
    private func promptUserForConfiguration() {
        // NSAlert の accessoryView 用のサイズ
        let accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 180))
        
        // インストール方法
        let methodLabel = NSTextField(labelWithString: "Install Way:")
        methodLabel.frame = NSRect(x: 0, y: 140, width: 120, height: 24)
        accessoryView.addSubview(methodLabel)
        
        let methodPopup = NSPopUpButton(frame: NSRect(x: 130, y: 140, width: 200, height: 26))
        methodPopup.addItems(withTitles: ["ISO", "VirtualCUBE Bundle"])
        accessoryView.addSubview(methodPopup)
        
        // ファイルパス（選択ボタンで NSOpenPanel を表示）
        let fileLabel = NSTextField(labelWithString: "Path:")
        fileLabel.frame = NSRect(x: 0, y: 105, width: 120, height: 24)
        accessoryView.addSubview(fileLabel)
        
        filePathField = NSTextField(frame: NSRect(x: 130, y: 105, width: 200, height: 24))
        filePathField.stringValue = ""
        filePathField.isEditable = false
        accessoryView.addSubview(filePathField)
        
        let browseButton = NSButton(title: "Select", target: self, action: #selector(browseForFile(_:)))
        browseButton.frame = NSRect(x: 340, y: 105, width: 50, height: 24)
        accessoryView.addSubview(browseButton)
        
        // メモリ容量
        let memoryLabel = NSTextField(labelWithString: "RAM Memory (GB):")
        memoryLabel.frame = NSRect(x: 0, y: 70, width: 120, height: 24)
        accessoryView.addSubview(memoryLabel)
        
        let memoryField = NSTextField(string: "\(memoryCapacityGB)")
        memoryField.frame = NSRect(x: 130, y: 70, width: 200, height: 24)
        accessoryView.addSubview(memoryField)
        
        // CPU コア数（ISO インストール時のみ有効）
        let cpuLabel = NSTextField(labelWithString: "CPU Core:")
        cpuLabel.frame = NSRect(x: 0, y: 35, width: 120, height: 24)
        accessoryView.addSubview(cpuLabel)
        
        let cpuFieldLocal = NSTextField(string: "\(userSelectedCPUCores)")
        cpuFieldLocal.frame = NSRect(x: 130, y: 35, width: 200, height: 24)
        accessoryView.addSubview(cpuFieldLocal)
        self.cpuField = cpuFieldLocal
        
        // ストレージ容量（GB）（ISO インストール時のみ有効）
        let storageLabel = NSTextField(labelWithString: "Storage (GB):")
        storageLabel.frame = NSRect(x: 0, y: 0, width: 120, height: 24)
        accessoryView.addSubview(storageLabel)
        
        let storageFieldLocal = NSTextField(string: "\(storageCapacityGB)")
        storageFieldLocal.frame = NSRect(x: 130, y: 0, width: 200, height: 24)
        accessoryView.addSubview(storageFieldLocal)
        self.storageField = storageFieldLocal
        
        // 初期状態：ISO インストールの場合は CPU とストレージを有効、永続化の場合は無効にする
        func updateFields(for method: String) {
            let isISO = (method == "ISO")
            cpuFieldLocal.isEnabled = isISO
            storageFieldLocal.isEnabled = isISO
        }
        updateFields(for: methodPopup.titleOfSelectedItem ?? "ISO")
        
        // インストール方法が変更されたときに CPU, ストレージフィールドの有効/無効を切り替える
        methodPopup.target = self
        methodPopup.action = #selector(installationMethodChanged(_:))
        
        let alert = NSAlert()
        alert.messageText = "Please Setup VirtualCUBE"
        alert.informativeText = "Install Way, RAM, Storage, CPU Core."
        alert.alertStyle = .informational
        alert.accessoryView = accessoryView
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            // インストール方法の取得
            if methodPopup.titleOfSelectedItem == "ISO" {
                installationMethod = .iso
            } else {
                installationMethod = .persistent
            }
            
            // ファイルパスが空ならエラー
            let selectedFilePath = filePathField.stringValue
            guard !selectedFilePath.isEmpty else {
                presentErrorAlert(message: "File Not Selected")
                return
            }
            // 常に URL(fileURLWithPath:) を使ってファイルURLを生成する
            let fileURL = URL(fileURLWithPath: selectedFilePath)
            
            // メモリ
            if let mem = UInt64(memoryField.stringValue), mem > 0 {
                memoryCapacityGB = mem
            }
            
            if installationMethod == .iso {
                // ISO インストールの場合は、CPUコア数とストレージを設定
                if let cpuCores = Int(cpuFieldLocal.stringValue), cpuCores > 0 {
                    userSelectedCPUCores = cpuCores
                }
                if let storage = UInt64(storageFieldLocal.stringValue), storage > 0 {
                    storageCapacityGB = storage
                }
                needsInstall = true
                installerISOPath = fileURL
            } else {
                // 永続化ファイルの場合：選択されたファイルを後で VM バンドルへコピー
                needsInstall = false
                installerISOPath = fileURL
            }
            
            // VM バンドル作成
            createVMBundle()
            
            // ISO インストールの場合はディスクイメージを新規作成、
            // 永続化の場合は、選択されたバンドルの中身を正しい場所へコピー
            if installationMethod == .iso {
                createMainDiskImage()
            } else {
                let fileManager = FileManager.default
                var isDirectory: ObjCBool = false
                if fileManager.fileExists(atPath: installerISOPath!.path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    // 選択されたのはバンドル（ディレクトリ）なので、中の各ファイルをコピー
                    let persistentBundleURL = installerISOPath!
                    let diskSource = persistentBundleURL.appendingPathComponent("Disk.img")
                    let machineIdentifierSource = persistentBundleURL.appendingPathComponent("MachineIdentifier")
                    let nvramSource = persistentBundleURL.appendingPathComponent("NVRAM")
                    
                    do {
                        try fileManager.copyItem(at: diskSource, to: URL(fileURLWithPath: mainDiskImagePath))
                        try fileManager.copyItem(at: machineIdentifierSource, to: URL(fileURLWithPath: machineIdentifierPath))
                        try fileManager.copyItem(at: nvramSource, to: URL(fileURLWithPath: efiVariableStorePath))
                    } catch {
                        presentErrorAlert(message: "永続化ファイルのコピーに失敗しました: \(error)")
                        return
                    }
                } else {
                    // 万が一、バンドルではなくファイルの場合はディスクイメージとしてコピー
                    do {
                        try fileManager.copyItem(at: installerISOPath!, to: URL(fileURLWithPath: mainDiskImagePath))
                    } catch {
                        presentErrorAlert(message: "永続化ファイルのコピーに失敗しました: \(error)")
                        return
                    }
                }
            }
            // VM 起動
            configureAndStartVirtualMachine()
        } else {
            presentErrorAlert(message: "Setting Canceled")
        }
    }
    
    @objc private func installationMethodChanged(_ sender: NSPopUpButton) {
        // タイトルが "ISO" の場合にCPUとストレージのフィールドを有効化
        let isISO = (sender.titleOfSelectedItem == "ISO")
        cpuField?.isEnabled = isISO
        storageField?.isEnabled = isISO
    }
    
    @objc private func browseForFile(_ sender: NSButton) {
        let openPanel = NSOpenPanel()
        openPanel.canChooseFiles = true
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canCreateDirectories = false

        // NSOpenPanel をモーダルパネルレベルに設定
        openPanel.level = .modalPanel

        // アプリをアクティブにしてキーウィンドウを前面に
        NSApp.activate(ignoringOtherApps: true)
        
        if let keyWindow = NSApp.keyWindow {
            openPanel.beginSheetModal(for: keyWindow) { [weak self] result in
                guard let self = self else { return }
                if result == .OK, let url = openPanel.url {
                    self.filePathField.stringValue = url.path
                    self.installerISOPath = url // ここで直接 URL を保持
                }
            }
        } else {
            // 万が一キーウィンドウが取得できなければフォールバック
            let response = openPanel.runModal()
            if response == .OK, let url = openPanel.url {
                self.filePathField.stringValue = url.path
                self.installerISOPath = url // ここでも直接 URL を保持
            }
        }
    }
    
    // エラー発生時のアラート表示
    private func presentErrorAlert(message: String) {
        let errorAlert = NSAlert()
        errorAlert.messageText = "Error"
        errorAlert.informativeText = message
        errorAlert.alertStyle = .critical
        errorAlert.addButton(withTitle: "OK")
        errorAlert.runModal()
    }
    
    // MARK: - NSApplicationDelegate
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // 毎回設定を問い合わせる
        promptUserForConfiguration()
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // ゲスト終了時にアプリが終了しないようにする
    }
    
    // MARK: - VZVirtualMachineDelegate
    
    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        presentErrorAlert(message: "仮想マシンがエラーで停止しました: \(error.localizedDescription)")
    }
    
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        // ゲストが停止してもアプリ自体は終了させない
        print("ゲストが停止しました。")
        // 必要に応じて、ユーザーに再起動を促すなどの処理を追加できます。
    }
    
    func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
        print("ネットワークアタッチメントが切断されました: \(error.localizedDescription)")
    }
}
