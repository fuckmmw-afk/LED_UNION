import { Capacitor, registerPlugin } from '@capacitor/core'

export type NativeBLEDevice = {
  id: string
  name: string
  rssi?: number
  driverId?: string
  connected?: boolean
}

export type NativeBLEEvent = {
  type: 'state' | 'discovered' | 'connected' | 'disconnected' | 'progress' | 'error' | 'diagnostic'
  deviceId?: string
  name?: string
  message?: string
  progress?: number
  frameHex?: string
}

export interface LEDNativeBLEPlugin {
  scan(options?: { timeoutMs?: number }): Promise<{ devices: NativeBLEDevice[] }>
  stopScan(): Promise<void>
  connect(options: { deviceId: string; name: string }): Promise<void>
  disconnect(options: { deviceId: string }): Promise<void>
  setColor(options: { deviceId: string; hex: string }): Promise<void>
  setBrightness(options: { deviceId: string; brightness: number }): Promise<void>
  setPower(options: { deviceId: string; on: boolean }): Promise<void>
  setEffect(options: { deviceId: string; effectId: number; name?: string }): Promise<void>
  /** Diagnostic escape hatch; normal UI actions use typed methods above. */
  sendRaw(options: { deviceId: string; hex: string; coalescingKey?: string }): Promise<void>
  diagnostics(options: { deviceId: string }): Promise<{ services: Array<{ uuid: string; characteristics: string[] }>; history?: Array<{ timestamp: string; kind: string; detail: string }> }>
  addListener(eventName: 'bleEvent', listenerFunc: (event: NativeBLEEvent) => void): Promise<{ remove: () => Promise<void> }>
}

export const LEDNativeBLE = registerPlugin<LEDNativeBLEPlugin>('LEDNativeBLE')
export const isNativeBLE = () => Capacitor.isNativePlatform() && Capacitor.getPlatform() === 'ios'

/** Native bridge only. Web Bluetooth remains the desktop/PWA fallback. */
export async function nativeSetColor(deviceId: string, hex: string) {
  if (!isNativeBLE()) throw new Error('Native BLE is only available in the iOS app')
  return LEDNativeBLE.setColor({ deviceId, hex })
}
