// upng-js ships no types. Only the two functions palette.ts calls are declared;
// the library does far more (encoding, quantisation, APNG) that this app has no
// use for, and declaring it would be inventing a contract we never exercise.
declare module 'upng-js' {
  interface UpngImage {
    width: number;
    height: number;
    depth: number;
    ctype: number;
    frames: unknown[];
    data: Uint8Array;
  }
  export function decode(buffer: ArrayBuffer | Uint8Array): UpngImage;
  /** One RGBA8 buffer per frame. A still PNG has exactly one. */
  export function toRGBA8(img: UpngImage): ArrayBuffer[];
}
