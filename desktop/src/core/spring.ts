// The lyric scroll spring's stepping maths, kept out of renderer.js so it can
// be tested at frame rates the app only sees in the wild.
//
// It used to take ONE explicit Euler step per animation frame. That is only
// stable while damping * dt stays well under 2: with the shipped stiffness 250
// and damping 50 it holds at 30 fps and diverges at 25 fps and below, where the
// velocity flips sign every frame and the position grows without bound. A
// fullscreen game (VALORANT on Windows was the report) starves Cascade's window
// of frames, so every new lyric line flung the whole sheet. At 60 fps nothing
// shows, which is why it only ever appeared while Cascade was not in front.
//
// So a frame now advances in fixed substeps no longer than SPRING_SUBSTEP_S,
// whatever the frame rate, and a gap long enough to mean the window was not
// drawing at all snaps to the target instead of replaying a stale move.

export interface SpringMotion {
  stiffness: number
  damping: number
}

export interface SpringState {
  pos: number
  vel: number
}

/** The largest step the integrator ever takes. Stable for damping well past
 *  anything the lyric motion knobs allow. */
export const SPRING_SUBSTEP_S = 1 / 240

/** A frame gap longer than this snaps to the target. */
export const SPRING_SNAP_GAP_S = 0.25

/** Close enough to the target, and slow enough, to call it settled. */
export const SPRING_SETTLE = 0.05

/**
 * Advances a spring by `dt` seconds toward `target`. Returns the new state and
 * whether it has settled (in which case it sits exactly on the target).
 * A non-finite or negative `dt` advances nothing.
 */
export function stepSpring(state: SpringState, target: number, dt: number, motion: SpringMotion):
  SpringState & { settled: boolean } {
  let { pos, vel } = state
  if (dt > SPRING_SNAP_GAP_S) return { pos: target, vel: 0, settled: true }
  let left = Number.isFinite(dt) && dt > 0 ? dt : 0
  while (left > 1e-9) {
    const h = Math.min(SPRING_SUBSTEP_S, left)
    const accel = (target - pos) * motion.stiffness - vel * motion.damping
    vel += accel * h
    pos += vel * h
    left -= h
  }
  const settled = Math.abs(target - pos) < SPRING_SETTLE && Math.abs(vel) < SPRING_SETTLE
  return settled ? { pos: target, vel: 0, settled } : { pos, vel, settled }
}
