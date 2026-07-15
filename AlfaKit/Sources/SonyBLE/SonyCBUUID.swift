import CoreBluetooth
import SonyProtocol

/// `CBUUID` values derived from the pure `SonyGATT` string constants.
///
/// Exposed as computed properties (each returns a fresh instance) so this holds no shared global state under Swift 6
/// strict concurrency.
public enum SonyCBUUID {
    public static var locationService: CBUUID { CBUUID(string: SonyGATT.Service.location) }
    public static var remoteControlService: CBUUID { CBUUID(string: SonyGATT.Service.remoteControl) }
    public static var cameraControlService: CBUUID { CBUUID(string: SonyGATT.Service.cameraControl) }
    public static var pairingService: CBUUID { CBUUID(string: SonyGATT.Service.pairing) }

    public static var locationWrite: CBUUID { CBUUID(string: SonyGATT.Characteristic.locationWrite) }
    public static var locationConfig: CBUUID { CBUUID(string: SonyGATT.Characteristic.locationConfig) }
    public static var locationUnlock: CBUUID { CBUUID(string: SonyGATT.Characteristic.locationUnlock) }
    public static var locationEnable: CBUUID { CBUUID(string: SonyGATT.Characteristic.locationEnable) }
    public static var locationNotify: CBUUID { CBUUID(string: SonyGATT.Characteristic.locationNotify) }

    public static var remoteCommand: CBUUID { CBUUID(string: SonyGATT.Characteristic.remoteCommand) }
    public static var remoteStatus: CBUUID { CBUUID(string: SonyGATT.Characteristic.remoteStatus) }

    public static var cameraPowerState: CBUUID { CBUUID(string: SonyGATT.Characteristic.cameraPowerState) }
    public static var cameraTimeSync: CBUUID { CBUUID(string: SonyGATT.Characteristic.cameraTimeSync) }
    public static var cameraBatteryInfo: CBUUID { CBUUID(string: SonyGATT.Characteristic.cameraBatteryInfo) }
}
