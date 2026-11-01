#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>
#include <time.h>
#include "RealmScope.h"
#if !__has_feature(objc_arc)
#error RealmInput requires ARC
#endif

// No text crosses this channel: only event permits, window identity and acknowledgements.
typedef struct {
  uint32_t magic;
  uint16_t version, kind;
  uint64_t nonce[2], sequence, value, detail;
} InputFrame;
_Static_assert(sizeof(InputFrame) == 48, "input frame ABI");

static const uint32_t inputMagic = UINT32_C(0x414C4749);
enum { Hello = 1, Arm = 2, Permit = 3, Finish = 4, Secure = 5,
       Ready = 0x8000, Delivered = 0x9000, Aborted = 0xffff };
static dispatch_source_t inputReader;
static id inputMonitor;
static NSMutableArray *inputNotifications;
static InputFrame request;
static size_t receivedBytes;
static uint64_t nonce[2], sequence, permitSequence, permitTag, heldMouseTag;
static unsigned expectedType, remainingEvents;
static pid_t launcherPID;
static NSWindow *targetWindow;
static NSRect targetFrame;
static BOOL connected, armed, aborted, secureRequired, keyDownPassed;
static int inputFD = -1;
static double permitTime;

static double monotonicTime(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC_RAW, &now);
  return now.tv_sec + now.tv_nsec / 1e9;
}

static BOOL reply(unsigned kind, uint64_t seq, uint64_t value) {
  if (inputFD < 0) return NO;
  InputFrame frame = { .magic = inputMagic, .version = 1, .kind = kind,
    .nonce = { nonce[0], nonce[1] }, .sequence = seq, .value = value };
  return send(inputFD, &frame, sizeof(frame), MSG_DONTWAIT) == sizeof(frame);
}

static void retireInputFD(void) {
  // Replace atomically: closing fd0 first lets another game thread reuse it.
  int null = open("/dev/null", O_RDONLY | O_CLOEXEC);
  if (null < 0) { close(STDIN_FILENO); return; }
  if (null != STDIN_FILENO) {
    (void)dup2(null, STDIN_FILENO);
    close(null);
  }
  (void)fcntl(STDIN_FILENO, F_SETFD, FD_CLOEXEC);
}

static void stopReader(void) {
  inputFD = -1;
  if (inputReader) { dispatch_source_cancel(inputReader); inputReader = nil; }
}

static void abortInput(void) {
  if (aborted) return;
  aborted = YES;
  if (connected) (void)reply(Aborted, sequence, 0);
  stopReader();
  for (id token in inputNotifications) [NSNotificationCenter.defaultCenter removeObserver:token];
  inputNotifications = nil;
  targetWindow = nil;
  // Keep the filter after abort/EOF so queued own input cannot escape during teardown.
}

static BOOL windowMatches(void) {
  return targetWindow && NSApp.isActive && targetWindow.isKeyWindow
    && targetWindow.isVisible && !targetWindow.isMiniaturized
    && !targetWindow.attachedSheet && (!NSApp.modalWindow || NSApp.modalWindow == targetWindow)
    && NSEqualRects(targetWindow.frame, targetFrame)
    && (!secureRequired || IsSecureEventInputEnabled());
}

static NSEvent *observeInput(NSEvent *event) {
  if (!armed) return event;
  CGEventRef cg = event.CGEvent;
  BOOL own = cg && CGEventGetIntegerValueField(cg, kCGEventSourceUnixProcessID) == launcherPID;
  uint64_t tag = cg ? (uint64_t)CGEventGetIntegerValueField(cg, kCGEventSourceUserData) : 0;
  unsigned type = cg ? (unsigned)CGEventGetType(cg) : UINT32_MAX;
  if (!own) { abortInput(); return event; }
  if (!aborted && inputFD >= 0) {
    char byte;
    ssize_t alive = recv(inputFD, &byte, 1, MSG_PEEK | MSG_DONTWAIT);
    if (!alive || (alive < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR)) {
      abortInput();
    }
  }
  // Releases remain paired even if a foreign event interrupted the down/up pair.
  if (aborted) {
    if (tag == permitTag && keyDownPassed && type == kCGEventKeyUp) {
      keyDownPassed = NO;
      return event;
    }
    if (heldMouseTag && (tag == heldMouseTag || tag == permitTag)
        && type == kCGEventLeftMouseUp) {
      heldMouseTag = 0;
      return event;
    }
    return nil;
  }
  if (!windowMatches() || !remainingEvents || monotonicTime() - permitTime > 0.3
      || !tag || tag != permitTag
      || type != expectedType || event.window != targetWindow) {
    BOOL releaseKey = tag == permitTag && keyDownPassed && type == kCGEventKeyUp;
    BOOL releaseMouse = heldMouseTag && type == kCGEventLeftMouseUp
      && (tag == heldMouseTag || tag == permitTag);
    abortInput();
    if (releaseKey) keyDownPassed = NO;
    if (releaseMouse) heldMouseTag = 0;
    return releaseKey || releaseMouse ? event : nil;
  }
  if (type == kCGEventKeyDown) keyDownPassed = YES;
  if (type == kCGEventKeyUp) keyDownPassed = NO;
  if (type == kCGEventLeftMouseDown) heldMouseTag = tag;
  if (type == kCGEventLeftMouseUp) heldMouseTag = 0;
  --remainingEvents;
  if (remainingEvents) ++expectedType;
  else if (!reply(Delivered, permitSequence, type)) {
    if (type == kCGEventLeftMouseDown) heldMouseTag = 0;
    abortInput();
    return type == kCGEventKeyUp || type == kCGEventLeftMouseUp ? event : nil;
  }
  return event;
}

static void handleFrame(void) {
  if (request.magic != inputMagic || request.version != 1 || request.sequence != sequence + 1) {
    abortInput(); return;
  }
  sequence = request.sequence;
  if (!connected) {
    if (request.kind != Hello || request.value != (uint64_t)getppid()
        || !(request.nonce[0] | request.nonce[1])) { abortInput(); return; }
    nonce[0] = request.nonce[0]; nonce[1] = request.nonce[1];
    launcherPID = getppid();
    connected = YES;
  } else if (request.nonce[0] != nonce[0] || request.nonce[1] != nonce[1]) {
    abortInput(); return;
  }
  switch (request.kind) {
    case Hello:
      if (sequence != 1 || request.detail) { abortInput(); return; }
      break;
    case Arm: {
      if (armed || remainingEvents || request.detail) { abortInput(); return; }
      for (NSWindow *window in NSApp.windows) {
        if ((uint64_t)window.windowNumber == request.value) { targetWindow = window; break; }
      }
      if (!targetWindow) { abortInput(); return; }
      targetFrame = targetWindow.frame;
      if (!windowMatches()) { abortInput(); return; }
      NSEventMask mask = NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged
        | NSEventMaskMouseMoved | NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp
        | NSEventMaskRightMouseDown | NSEventMaskRightMouseUp
        | NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp | NSEventMaskScrollWheel
        | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged
        | NSEventMaskOtherMouseDragged | NSEventMaskSystemDefined;
      inputMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask
        handler:^NSEvent *(NSEvent *event) { return observeInput(event); }];
      if (!inputMonitor) { abortInput(); return; }
      armed = YES;
      inputNotifications = [NSMutableArray array];
      NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
      for (NSNotificationName name in @[NSApplicationDidResignActiveNotification,
          NSWindowDidResignKeyNotification, NSWindowDidMoveNotification,
          NSWindowDidResizeNotification, NSWindowWillMiniaturizeNotification,
          NSWindowWillCloseNotification, NSWindowWillBeginSheetNotification]) {
        id token = [center addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
          usingBlock:^(NSNotification *note) {
            if (note.object == NSApp || note.object == targetWindow) abortInput();
          }];
        [inputNotifications addObject:token];
      }
      break;
    }
    case Permit: {
      unsigned type = (unsigned)(request.detail >> 32);
      unsigned count = (unsigned)request.detail;
      BOOL valid = (type == kCGEventKeyDown && count == 2)
        || ((type == kCGEventMouseMoved || type == kCGEventLeftMouseDown
             || type == kCGEventLeftMouseUp) && count == 1);
      if (!armed || !windowMatches() || remainingEvents || !request.value || !valid
          || keyDownPassed || (heldMouseTag && type != kCGEventLeftMouseUp)
          || (!heldMouseTag && type == kCGEventLeftMouseUp)) {
        abortInput(); return;
      }
      permitTag = request.value;
      permitSequence = sequence;
      expectedType = type;
      remainingEvents = count;
      permitTime = monotonicTime();
      break;
    }
    case Secure:
      if (!armed || !windowMatches() || remainingEvents || keyDownPassed || heldMouseTag
          || request.value || request.detail
          || !IsSecureEventInputEnabled()) { abortInput(); return; }
      secureRequired = YES;
      break;
    case Finish:
      if (!armed || remainingEvents || keyDownPassed || heldMouseTag
          || request.value || request.detail) { abortInput(); return; }
      if (!reply(Ready | Finish, sequence, 0)) { abortInput(); return; }
      armed = NO;
      if (inputMonitor) [NSEvent removeMonitor:inputMonitor];
      inputMonitor = nil;
      for (id token in inputNotifications) [NSNotificationCenter.defaultCenter removeObserver:token];
      inputNotifications = nil;
      targetWindow = nil;
      stopReader();
      return;
    default: abortInput(); return;
  }
  if (!reply(Ready | request.kind, sequence, 0)) abortInput();
}

__attribute__((constructor)) static void startInputChannel(void) {
  const char *enabled = getenv("FOREVER_INPUT_CHANNEL");
  BOOL requested = enabled && !strcmp(enabled, "1");
  unsetenv("FOREVER_INPUT_CHANNEL");
  if (!requested || !realmPrivateProcess()) return;
  int type = 0;
  socklen_t size = sizeof(type);
  struct sockaddr_storage address;
  socklen_t addressSize = sizeof(address);
  if (getsockopt(STDIN_FILENO, SOL_SOCKET, SO_TYPE, &type, &size) || type != SOCK_STREAM
      || getsockname(STDIN_FILENO, (struct sockaddr *)&address, &addressSize)
      || address.ss_family != AF_UNIX) return;
  int flags = fcntl(STDIN_FILENO, F_GETFL);
  int one = 1;
  if (flags < 0 || fcntl(STDIN_FILENO, F_SETFL, flags | O_NONBLOCK)
      || fcntl(STDIN_FILENO, F_SETFD, FD_CLOEXEC)
      || setsockopt(STDIN_FILENO, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one))) return;
  inputFD = STDIN_FILENO;
  dispatch_async(dispatch_get_main_queue(), ^{
    inputReader = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, inputFD, 0,
      dispatch_get_main_queue());
    if (!inputReader) { inputFD = -1; retireInputFD(); return; }
    dispatch_source_set_cancel_handler(inputReader, ^{ retireInputFD(); });
    dispatch_source_set_event_handler(inputReader, ^{
      for (unsigned turns = 0; turns < 8 && inputFD >= 0; ++turns) {
        ssize_t count = recv(inputFD, (char *)&request + receivedBytes,
          sizeof(request) - receivedBytes, MSG_DONTWAIT);
        if (!count) { abortInput(); return; }
        if (count < 0) {
          if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) abortInput();
          return;
        }
        receivedBytes += (size_t)count;
        if (receivedBytes == sizeof(request)) { receivedBytes = 0; handleFrame(); }
      }
    });
    dispatch_resume(inputReader);
  });
}
