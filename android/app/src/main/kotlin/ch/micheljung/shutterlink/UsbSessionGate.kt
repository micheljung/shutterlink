package ch.micheljung.shutterlink

/**
 * Decides whether a pipe call may touch the open device. Each open gets a new
 * id, so a call from a pipe that a later open replaced is refused instead of
 * running on, and stealing reads from, the new session.
 */
object UsbSessionGate {
    enum class Rejection { NOT_OPEN, STALE }

    fun check(openId: Int?, requestedId: Int?): Rejection? = when {
        openId == null -> Rejection.NOT_OPEN
        requestedId != openId -> Rejection.STALE
        else -> null
    }
}
