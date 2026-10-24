/// The virtual Striso board: the firmware's own code (synth control, every voice engine and the
/// effects, the USB console protocol, the config store) as a library on the PC, from
/// striso-control-firmware (virtual/, the striso_virtual library). Behind [VirtualBoardTransport]
/// it is a board on USB to StrisoClient; [VirtualBoard] renders its audio, injects keys and
/// motion and shows its LEDs; [VirtualPlayer] plays it by hand.
library;

export 'src/bindings.dart'
    show
        StrisoVirtualLib,
        svApiVersion,
        strisoVirtualCandidates,
        svUsbAttached,
        svUsbBootloader,
        svUsbDetached,
        svLedOff,
        svLedDim,
        svLedOn,
        svTestFxInit,
        svTestMotionOff,
        svFlashSize;
export 'src/board.dart';
export 'src/player.dart';
export 'src/transport.dart';
