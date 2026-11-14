// Paste this entire file into a new Xcode iOS App project's ContentView.swift.
// The project's generated YourProjectNameApp.swift stays unchanged.
// Requires a real iPhone (CoreBluetooth does not run in iOS Simulator).
import SwiftUI
import CoreBluetooth
import UIKit

private enum BridgeUUID {
    static let service = CBUUID(string: "4A8BD2B0-A3B1-4A94-B8AD-49C2F6001000")
    static let title   = CBUUID(string: "4A8BD2B0-A3B1-4A94-B8AD-49C2F6001001")
    static let artist  = CBUUID(string: "4A8BD2B0-A3B1-4A94-B8AD-49C2F6001002")
    static let artwork = CBUUID(string: "4A8BD2B0-A3B1-4A94-B8AD-49C2F6001003")
}

final class ArtworkBridge: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var status = "Starting Bluetooth..."
    @Published var title = ""
    @Published var artist = ""
    @Published var matchedSong = ""
    @Published var cover: UIImage?
    @Published var isConnected = false
    @Published var lastBLEUpdate = "No song data received from ESP32 yet"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var artworkCharacteristic: CBCharacteristic?
    private var lookupWork: DispatchWorkItem?
    private var lookupID = 0
    private var packetQueue: [Data] = []
    private var packetIndex = 0
    private var artworkBytes = 0
    private var titleCharacteristic: CBCharacteristic?
    private var artistCharacteristic: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            scan()
        } else {
            status = "Bluetooth unavailable: \(central.state.rawValue)"
            isConnected = false
        }
    }

    func scan() {
        guard central.state == .poweredOn else { return }
        status = "Scanning for S3 Music..."
        // Scan without a UUID filter: the ESP32 advertises its bridge UUID
        // in the scan response, which may not satisfy an iOS service filter.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        guard self.peripheral == nil else { return }
        // Do not connect to arbitrary nearby BLE devices.
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = localName ?? peripheral.name ?? ""
        let advertisedServices = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
        guard name == "S3 Music" || advertisedServices.contains(BridgeUUID.service) else { return }
        self.peripheral = peripheral
        self.peripheral?.delegate = self
        central.stopScan()
        status = "Connecting to ESP32-S3..."
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        status = "Connected. Discovering music bridge..."
        isConnected = true
        peripheral.discoverServices([BridgeUUID.service])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        status = "Connection failed: \(error?.localizedDescription ?? "unknown")"
        self.peripheral = nil
        artworkCharacteristic = nil
        titleCharacteristic = nil
        artistCharacteristic = nil
        isConnected = false
        scan()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        status = "Disconnected. Scanning again..."
        self.peripheral = nil
        artworkCharacteristic = nil
        titleCharacteristic = nil
        artistCharacteristic = nil
        isConnected = false
        packetQueue = []
        scan()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error = error { status = "Service error: \(error.localizedDescription)"; return }
        guard let service = peripheral.services?.first(where: { $0.uuid == BridgeUUID.service }) else {
            status = "Bridge service not found"
            return
        }
        peripheral.discoverCharacteristics([BridgeUUID.title, BridgeUUID.artist, BridgeUUID.artwork], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error = error { status = "Characteristic error: \(error.localizedDescription)"; return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == BridgeUUID.title {
                titleCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            }
            if characteristic.uuid == BridgeUUID.artist {
                artistCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
            }
            if characteristic.uuid == BridgeUUID.artwork {
                artworkCharacteristic = characteristic
            }
        }
        status = artworkCharacteristic == nil ? "Artwork characteristic missing" : "Ready — play YouTube Music"
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let bytes = characteristic.value,
              let value = String(data: bytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if characteristic.uuid == BridgeUUID.title {
            if title != value {
                title = value
                lastBLEUpdate = "Received song: \(value)"
                scheduleLookup()
            }
        } else if characteristic.uuid == BridgeUUID.artist {
            if artist != value {
                artist = value
                lastBLEUpdate = "Received artist: \(value)"
                scheduleLookup()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            lastBLEUpdate = "Notification setup failed: \(error.localizedDescription)"
            return
        }
        if characteristic.isNotifying {
            lastBLEUpdate = "Subscribed to BLE song updates"
            // A song may already be playing when the companion app connects.
            peripheral.readValue(for: characteristic)
        }
    }

    private func scheduleLookup() {
        lookupWork?.cancel()
        guard !title.isEmpty, !artist.isEmpty else { return }
        let work = DispatchWorkItem { [weak self] in self?.findCover() }
        lookupWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    // Can also be called from the manual Search button for debugging.
    func findCover() {
        guard !title.isEmpty, !artist.isEmpty else {
            status = "Enter a title and artist first"
            return
        }
        lookupID += 1
        let id = lookupID
        cover = nil
        matchedSong = ""
        status = "Searching for album artwork..."
        queryArtwork(country: "US", id: id)
    }

    private func queryArtwork(country: String, id: Int) {
        var url = URLComponents(string: "https://itunes.apple.com/search")!
        url.queryItems = [
            URLQueryItem(name: "term", value: "\(title) \(artist)"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15"),
            URLQueryItem(name: "country", value: country)
        ]
        guard let endpoint = url.url else { return }
        URLSession.shared.dataTask(with: endpoint) { [weak self] data, response, error in
            guard let self = self else { return }
            guard let data = data,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = object["results"] as? [[String: Any]] else {
                DispatchQueue.main.async {
                    if id == self.lookupID { self.status = "Artwork search failed. Check cellular internet." }
                }
                return
            }
            DispatchQueue.main.async {
                guard id == self.lookupID else { return }
                let normalizedTitle = self.clean(self.title)
                let normalizedArtist = self.clean(self.artist)
                // Reject weak matches rather than showing an unrelated image.
                let best = results.first { result in
                    let t = self.clean(result["trackName"] as? String ?? "")
                    let a = self.clean(result["artistName"] as? String ?? "")
                    return (t == normalizedTitle || t.contains(normalizedTitle) || normalizedTitle.contains(t)) &&
                           (a.contains(normalizedArtist) || normalizedArtist.contains(a)) &&
                           !t.isEmpty && !a.isEmpty
                }
                if let best = best,
                   let address = best["artworkUrl100"] as? String,
                   let imageURL = URL(string: address) {
                    self.matchedSong = "\(best["trackName"] as? String ?? "") — \(best["artistName"] as? String ?? "")"
                    self.downloadCover(imageURL, id: id)
                } else if country == "US" {
                    self.queryArtwork(country: "VN", id: id)
                } else {
                    self.status = "No confident match found (US/VN catalogs)"
                }
            }
        }.resume()
    }

    private func clean(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func downloadCover(_ url: URL, id: Int) {
        status = "Downloading matched cover on iPhone..."
        URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            guard let self = self, let data = data, let original = UIImage(data: data) else {
                DispatchQueue.main.async { if id == self?.lookupID { self?.status = "Artwork download failed" } }
                return
            }
            // Resize on the phone: ESP32 only needs a small JPEG.
            let size = CGSize(width: 100, height: 100)
            let renderer = UIGraphicsImageRenderer(size: size)
            let small = renderer.image { _ in original.draw(in: CGRect(origin: .zero, size: size)) }
            guard let jpeg = small.jpegData(compressionQuality: 0.60) else { return }
            DispatchQueue.main.async {
                guard id == self.lookupID else { return }
                self.cover = small
                self.sendJPEG(jpeg)
            }
        }.resume()
    }

    private func sendJPEG(_ jpeg: Data) {
        guard let peripheral = peripheral,
              let characteristic = artworkCharacteristic else {
            status = "Cover found. Connect ESP32 to send it."
            return
        }
        guard jpeg.count <= 30000 else {
            status = "Cover too large (\(jpeg.count) bytes)"
            return
        }
        packetQueue = []
        packetIndex = 0
        artworkBytes = jpeg.count

        var start = Data([0x01])
        var lengthLE = UInt32(jpeg.count).littleEndian
        withUnsafeBytes(of: &lengthLE) { start.append(contentsOf: $0) }
        packetQueue.append(start)

        let maxPacket = peripheral.maximumWriteValueLength(for: .withResponse)
        let bytesPerChunk = max(1, min(180, maxPacket - 1))
        var offset = 0
        while offset < jpeg.count {
            let end = min(offset + bytesPerChunk, jpeg.count)
            var packet = Data([0x02])
            packet.append(jpeg.subdata(in: offset..<end))
            packetQueue.append(packet)
            offset = end
        }
        packetQueue.append(Data([0x03]))
        status = "Sending \(jpeg.count) JPEG bytes over Bluetooth..."
        sendNextPacket()
    }

    private func sendNextPacket() {
        guard let p = peripheral, let ch = artworkCharacteristic else { return }
        if packetIndex >= packetQueue.count {
            status = "Image transmitted (\(artworkBytes) bytes). Check Arduino Serial Monitor."
            packetQueue = []
            return
        }
        let packet = packetQueue[packetIndex]
        p.writeValue(packet, for: ch, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error = error {
            packetQueue = []
            status = "BLE send error: \(error.localizedDescription)"
            return
        }
        guard characteristic.uuid == BridgeUUID.artwork, !packetQueue.isEmpty else { return }
        packetIndex += 1
        sendNextPacket()
    }
}

struct ContentView: View {
    @StateObject private var bridge = ArtworkBridge()

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("S3 Music Artwork")
                    .font(.largeTitle.bold())
                Text(bridge.status)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                if let image = bridge.cover {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                        .frame(width: 220, height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.gray.opacity(0.16))
                        .frame(width: 220, height: 220)
                        .overlay(Image(systemName: "music.note").font(.system(size: 48)))
                }
                Text(bridge.lastBLEUpdate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Song title", text: $bridge.title)
                    .textFieldStyle(.roundedBorder)
                TextField("Artist", text: $bridge.artist)
                    .textFieldStyle(.roundedBorder)
                if !bridge.matchedSong.isEmpty {
                    Text("Matched: \(bridge.matchedSong)")
                        .font(.caption)
                }
                Button("Find & Send Artwork") { bridge.findCover() }
                    .buttonStyle(.borderedProminent)
                    .disabled(bridge.title.isEmpty || bridge.artist.isEmpty)
                Button("Reconnect to ESP32") { bridge.scan() }
                    .buttonStyle(.bordered)
                Text("This app looks up matching artwork using your iPhone's internet connection. The ESP32 uses Bluetooth only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
        }
    }
}
