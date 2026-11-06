import AxoProtocol
import CryptoKit
import Foundation

/// This phone's answer-signing key (RFD0029, every remote answer is signed): made once, in the
/// Secure Enclave, where its private half never leaves the phone. What is kept in the defaults is
/// a blob only this phone's Secure Enclave can use. Where there is none (the simulator), a
/// software key stands in.
public enum PhoneDeviceKey {
  private static let enclaveName = "axo.deviceKey.enclave"
  private static let softwareName = "axo.deviceKey.software"

  public static func stored(in defaults: UserDefaults = .standard) -> any DeviceSigner {
    if SecureEnclave.isAvailable {
      if let signer = try? SecureEnclaveDeviceSigner(dataRepresentation: defaults.data(forKey: enclaveName)) {
        defaults.set(signer.dataRepresentation, forKey: enclaveName)
        return signer
      }
    }
    if let raw = defaults.data(forKey: softwareName),
      let key = try? P256.Signing.PrivateKey(rawRepresentation: raw)
    {
      return SoftwareDeviceSigner(key: key)
    }
    let key = P256.Signing.PrivateKey()
    defaults.set(key.rawRepresentation, forKey: softwareName)
    return SoftwareDeviceSigner(key: key)
  }
}
