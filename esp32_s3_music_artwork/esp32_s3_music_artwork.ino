/*
 * ESP32-S3 AMS + BLE artwork bridge, no display required.
 * Arduino ESP32, NimBLE-Arduino 2.3.x (h2zero).
 *
 * Phone -> ESP32: Apple Media Service (AMS) song metadata.
 * ESP32 -> companion app: custom title/artist notifications.
 * Companion app -> ESP32: JPEG fragments on custom GATT characteristic.
 */
#include <Arduino.h>
#include <NimBLEDevice.h>

// Apple's AMS UUIDs
static const char* AMS_SERVICE = "89D3502B-0F36-433A-8EF4-C502AD55F8DC";
static const char* AMS_UPDATE  = "2F7CABCE-808D-411F-9A0C-BB92BA96C102";

// Our own BLE GATT service, shared with ContentView.swift.
static const char* BRIDGE_SERVICE = "4A8BD2B0-A3B1-4A94-B8AD-49C2F6001000";
static const char* TITLE_UUID     = "4A8BD2B0-A3B1-4A94-B8AD-49C2F6001001";
static const char* ARTIST_UUID    = "4A8BD2B0-A3B1-4A94-B8AD-49C2F6001002";
static const char* ARTWORK_UUID   = "4A8BD2B0-A3B1-4A94-B8AD-49C2F6001003";

NimBLEClient* amsClient = nullptr;
NimBLECharacteristic* titleCharacteristic = nullptr;
NimBLECharacteristic* artistCharacteristic = nullptr;

bool amsReady = false;
unsigned long lastAMSAttempt = 0;
String songTitle, songArtist;
String lastSentTitle, lastSentArtist;

// First experiment supports <= 30 KiB JPEGs. 100x100 usually fits.
static constexpr size_t MAX_ART_BYTES = 30000;
uint8_t artwork[MAX_ART_BYTES];
size_t expectedBytes = 0;
size_t receivedBytes = 0;
bool receivingArtwork = false;

// Simple packet protocol:
// 0x01 + uint32 little-endian length: start image
// 0x02 + JPEG payload: image fragment
// 0x03: finish image
class ArtworkCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* characteristic,
               NimBLEConnInfo& connection) override {
    // NimBLE-Arduino 2.x calls onWrite with two arguments.
    // Read a safe copy of the value written by the iPhone app.
    NimBLEAttValue value = characteristic->getValue();
    const uint8_t* bytes = value.data();
    size_t len = value.size();
    if (len == 0) return;

    if (bytes[0] == 0x01 && len == 5) {
      uint32_t total = ((uint32_t)bytes[1]) |
                       ((uint32_t)bytes[2] << 8) |
                       ((uint32_t)bytes[3] << 16) |
                       ((uint32_t)bytes[4] << 24);
      expectedBytes = total;
      receivedBytes = 0;
      receivingArtwork = (total > 0 && total <= MAX_ART_BYTES);
      Serial.printf("ART START: expected %lu bytes\n", (unsigned long)total);
      if (!receivingArtwork) Serial.println("ART ERROR: JPEG exceeds 30000-byte limit");
    } else if (bytes[0] == 0x02 && receivingArtwork) {
      size_t chunk = len - 1;
      if (receivedBytes + chunk > expectedBytes ||
          receivedBytes + chunk > MAX_ART_BYTES) {
        receivingArtwork = false;
        Serial.println("ART ERROR: length overflow");
      } else {
        memcpy(artwork + receivedBytes, bytes + 1, chunk);
        receivedBytes += chunk;
      }
    } else if (bytes[0] == 0x03) {
      bool valid = receivingArtwork && receivedBytes == expectedBytes &&
                   receivedBytes >= 4 &&
                   artwork[0] == 0xFF && artwork[1] == 0xD8 &&
                   artwork[receivedBytes-2] == 0xFF &&
                   artwork[receivedBytes-1] == 0xD9;
      if (valid) {
        Serial.printf("ART SUCCESS: received a %lu-byte JPEG via BLE!\n",
                      (unsigned long)receivedBytes);
        Serial.println("Image is in RAM; attach a screen in the next stage.");
      } else {
        Serial.printf("ART ERROR: incomplete/invalid JPEG (%lu/%lu)\n",
                      (unsigned long)receivedBytes, (unsigned long)expectedBytes);
      }
      receivingArtwork = false;
    }
  }
};

ArtworkCallbacks artworkCallbacks;

void onMusicUpdate(NimBLERemoteCharacteristic* characteristic,
                   uint8_t* data, size_t length, bool isNotify) {
  if (length < 3) return;
  uint8_t entity = data[0], attribute = data[1];
  String value;
  for (size_t i = 3; i < length; ++i) value += (char)data[i];
  if (entity == 2 && attribute == 0) { // Track artist
    songArtist = value;
    Serial.print("Artist: "); Serial.println(value);
  } else if (entity == 2 && attribute == 2) { // Track title
    songTitle = value;
    Serial.print("Song: "); Serial.println(value);
  } else if (entity == 0 && attribute == 0) {
    Serial.print("Player: "); Serial.println(value);
  }
}

class PhoneCallbacks : public NimBLEServerCallbacks {
  void onConnect(NimBLEServer* server, NimBLEConnInfo& info) override {
    Serial.println("BLE peer connected");
    if (amsClient == nullptr || !amsClient->isConnected()) {
      amsClient = server->getClient(info);
      amsReady = false;
      lastAMSAttempt = 0;
    }
    // Keep advertising so the companion app can discover the GATT bridge,
    // even when the iPhone has already opened the AMS connection.
    NimBLEDevice::getAdvertising()->start();
  }

  void onDisconnect(NimBLEServer* server, NimBLEConnInfo& info, int reason) override {
    Serial.println("BLE peer disconnected");
    if (amsClient == nullptr || !amsClient->isConnected()) {
      amsClient = nullptr;
      amsReady = false;
    }
  }

  void onAuthenticationComplete(NimBLEConnInfo& info) override {
    Serial.println(info.isEncrypted() ? "BLE security OK" : "BLE security not established");
  }
};
PhoneCallbacks phoneCallbacks;

bool subscribeAMS() {
  if (!amsClient || !amsClient->isConnected()) return false;
  Serial.println("Looking for iPhone Apple Media Service...");
  if (!amsClient->secureConnection()) return false;
  NimBLERemoteService* service = amsClient->getService(AMS_SERVICE);
  if (!service) return false;
  NimBLERemoteCharacteristic* update = service->getCharacteristic(AMS_UPDATE);
  if (!update || !update->subscribe(true, onMusicUpdate)) return false;
  uint8_t trackRequest[] = {2, 0, 1, 2, 3};
  uint8_t playerRequest[] = {0, 0, 1};
  if (!update->writeValue(trackRequest, sizeof(trackRequest), true)) return false;
  if (!update->writeValue(playerRequest, sizeof(playerRequest), true)) return false;
  Serial.println("AMS subscribed successfully!");
  return true;
}

void setup() {
  Serial.begin(115200);
  delay(1200);
  Serial.println("ESP32-S3 Music + Artwork Bridge");

  NimBLEDevice::init("S3 Music");
  NimBLEDevice::setSecurityAuth(true, false, true);
  NimBLEDevice::setSecurityIOCap(BLE_HS_IO_NO_INPUT_OUTPUT);
  NimBLEDevice::setMTU(247);

  NimBLEServer* server = NimBLEDevice::createServer();
  server->setCallbacks(&phoneCallbacks, false);
  server->advertiseOnDisconnect(true);

  NimBLEService* bridge = server->createService(BRIDGE_SERVICE);
  titleCharacteristic = bridge->createCharacteristic(
    TITLE_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY, 200);
  artistCharacteristic = bridge->createCharacteristic(
    ARTIST_UUID, NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY, 200);
  NimBLECharacteristic* incomingArt = bridge->createCharacteristic(
    ARTWORK_UUID, NIMBLE_PROPERTY::WRITE, 512);
  incomingArt->setCallbacks(&artworkCallbacks);
  titleCharacteristic->setValue(" ");
  artistCharacteristic->setValue(" ");
  bridge->start();
  server->start();

  // Reuse the same AMS solicitation advertisement that worked for your iPhone.
  const uint8_t solicitation[] = {
    0x11, 0x15,
    0xDC, 0xF8, 0x55, 0xAD, 0x02, 0xC5, 0xF4, 0x8E,
    0x3A, 0x43, 0x36, 0x0F, 0x2B, 0x50, 0xD3, 0x89
  };
  NimBLEAdvertisementData primary;
  primary.setFlags(0x06);
  primary.setName("S3 Music");
  primary.addData(solicitation, sizeof(solicitation));

  NimBLEAdvertisementData scanResponse;
  scanResponse.addServiceUUID(BRIDGE_SERVICE);

  NimBLEAdvertising* advertising = server->getAdvertising();
  advertising->setAdvertisementData(primary);
  advertising->setScanResponseData(scanResponse);
  advertising->enableScanResponse(true);
  Serial.println(advertising->start() ? "BLE advertising started" : "BLE advertising FAILED");
  Serial.println("Pair S3 Music to your iPhone; then open the iOS artwork app.");
}

void loop() {
  if (amsClient != nullptr && amsClient->isConnected() && !amsReady &&
      (lastAMSAttempt == 0 || millis() - lastAMSAttempt >= 5000)) {
    lastAMSAttempt = millis();
    amsReady = subscribeAMS();
  }

  // Notify bridge app when the metadata changes.
  if (songTitle != lastSentTitle) {
    lastSentTitle = songTitle;
    titleCharacteristic->setValue(std::string(songTitle.c_str()));
    titleCharacteristic->notify();
  }
  if (songArtist != lastSentArtist) {
    lastSentArtist = songArtist;
    artistCharacteristic->setValue(std::string(songArtist.c_str()));
    artistCharacteristic->notify();
  }
  delay(80);
}
