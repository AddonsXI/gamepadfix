--[[
* Addons - Copyright (c) 2021 Ashita Development Team
* Contact: https://www.ashitaxi.com/
* Contact: https://discord.gg/Ashita
*
* This file is part of Ashita.
*
* Ashita is free software: you can redistribute it and/or modify
* it under the terms of the GNU General Public License as published by
* the Free Software Foundation, either version 3 of the License, or
* (at your option) any later version.
*
* Ashita is distributed in the hope that it will be useful,
* but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
* GNU General Public License for more details.
*
* You should have received a copy of the GNU General Public License
* along with Ashita.  If not, see <https://www.gnu.org/licenses/>.
--]]

addon.name      = 'gamepadfix';
addon.author    = 'AddonsXI';
addon.version   = '1.1.2';
addon.link      = 'https://github.com/AddonsXI';
addon.desc      = 'Turns the gamepad setting off when no controller is connected, and back on when one arrives.';

require('common');
local chat = require('chat');
local ffi = require('ffi');

--[[
* Fixed width types are used throughout rather than the win32types typedefs, so the
* declarations stay correct under FFXI's 32 bit process where void* is 4 bytes.
--]]
ffi.cdef[[
    typedef struct {
        void*    hDevice;
        uint32_t dwType;
    } RAWINPUTDEVICELIST;

    typedef struct {
        uint32_t dwId;
        uint32_t dwNumberOfButtons;
        uint32_t dwSampleRate;
        int32_t  fHasHorizontalWheel;
    } RID_DEVICE_INFO_MOUSE;

    typedef struct {
        uint32_t dwType;
        uint32_t dwSubType;
        uint32_t dwKeyboardMode;
        uint32_t dwNumberOfFunctionKeys;
        uint32_t dwNumberOfIndicators;
        uint32_t dwNumberOfKeysTotal;
    } RID_DEVICE_INFO_KEYBOARD;

    typedef struct {
        uint32_t dwVendorId;
        uint32_t dwProductId;
        uint32_t dwVersionNumber;
        uint16_t usUsagePage;
        uint16_t usUsage;
    } RID_DEVICE_INFO_HID;

    /* All three members are needed even though only hid is read. Windows validates
       cbSize, and the keyboard member is the largest, so declaring hid alone would
       give a 16 byte struct where Windows expects 32 and the call would fail. The
       union is named rather than anonymous to avoid relying on anonymous member
       support in the FFI. */
    typedef union {
        RID_DEVICE_INFO_MOUSE    mouse;
        RID_DEVICE_INFO_KEYBOARD keyboard;
        RID_DEVICE_INFO_HID      hid;
    } RID_DEVICE_INFO_UNION;

    typedef struct {
        uint32_t              cbSize;
        uint32_t              dwType;
        RID_DEVICE_INFO_UNION u;
    } RID_DEVICE_INFO;

    uint32_t GetRawInputDeviceList(RAWINPUTDEVICELIST* pRawInputDeviceList, uint32_t* puiNumDevices, uint32_t cbSize);
    uint32_t GetRawInputDeviceInfoA(void* hDevice, uint32_t uiCommand, void* pData, uint32_t* pcbSize);

    typedef struct {
        uintptr_t Internal;
        uintptr_t InternalHigh;
        uint32_t  Offset;
        uint32_t  OffsetHigh;
        void*     hEvent;
    } GPF_OVERLAPPED;

    void*    CreateFileA(const char* lpFileName, uint32_t dwDesiredAccess, uint32_t dwShareMode, void* lpSecurityAttributes, uint32_t dwCreationDisposition, uint32_t dwFlagsAndAttributes, void* hTemplateFile);
    void*    CreateEventA(void* lpEventAttributes, int32_t bManualReset, int32_t bInitialState, const char* lpName);
    int32_t  ReadFile(void* hFile, void* lpBuffer, uint32_t nNumberOfBytesToRead, uint32_t* lpNumberOfBytesRead, void* lpOverlapped);
    int32_t  GetOverlappedResult(void* hFile, void* lpOverlapped, uint32_t* lpNumberOfBytesTransferred, int32_t bWait);
    int32_t  CancelIoEx(void* hFile, void* lpOverlapped);
    int32_t  CloseHandle(void* hObject);
    uint32_t GetLastError(void);

    typedef struct {
        uint32_t dwPacketNumber;
        uint16_t wButtons;
        uint8_t  bLeftTrigger;
        uint8_t  bRightTrigger;
        int16_t  sThumbLX;
        int16_t  sThumbLY;
        int16_t  sThumbRX;
        int16_t  sThumbRY;
    } XINPUT_STATE;

    uint32_t XInputGetState(uint32_t dwUserIndex, XINPUT_STATE* pState);
]];

-- The pcall is required, not defensive: ffi.load raises rather than returning nil, so an
-- or-chain would abort on the first missing dll. Any future ffi.load must come through here.
local function loadLibrary(...)
    for _, name in ipairs({...}) do
        local ok, lib = pcall(ffi.load, name);
        if ok and lib ~= nil then
            return lib;
        end
    end
    return nil;
end

local user32 = loadLibrary('user32');
local kernel32 = loadLibrary('kernel32');
local xinput = loadLibrary('xinput1_4', 'xinput1_3', 'xinput9_1_0');

--[[ Every window in this file is measured with os.clock, which in LuaJIT is process
     CPU time rather than wall time, so they all stretch while the game is idle. That is
     harmless here: a stretched window only delays a verdict, and the addon assumes the
     controller is present until proven otherwise. ]]
local CHECK_INTERVAL = 1.0;
local API_FAILURE = 0xFFFFFFFF;
local RIM_TYPEHID = 2;
local RIDI_DEVICENAME = 0x20000007;
local RIDI_DEVICEINFO = 0x2000000b;
local USAGE_PAGE_GENERIC_DESKTOP = 0x01;

--[[ Joystick counts as well as gamepad, since some third party pads declare themselves
     one. A wheel, a flight stick or a set of pedals therefore counts as a controller,
     which is deliberate: a false negative kills a live player's input, while a false
     positive only leaves the gamepad enabled for someone not using one. ]]
local USAGE_JOYSTICK = 0x04;
local USAGE_GAMEPAD = 0x05;
local XUSER_MAX_COUNT = 4;
local ERROR_SUCCESS = 0;
local ERROR_DEVICE_NOT_CONNECTED = 1167;

-- A live pad has never been seen silent for more than a few tens of milliseconds.
local LIVENESS_TIMEOUT = 3.0;

-- Longer for a device that has never reported, in case it only speaks on change.
local UNPROVEN_TIMEOUT = 10.0;
local READ_SIZE = 1024;

-- The buffer and the size handed to GetRawInputDeviceInfoA, so the two cannot drift.
local NAME_BUFFER_SIZE = 512;

local EVENT_MANUAL_RESET = 1;
local EVENT_START_UNSIGNALLED = 0;

-- The last argument to GetOverlappedResult. Waiting is only safe during teardown, where
-- the handle is about to go. On the polling path it would freeze the render thread.
local WAIT = 1;
local NO_WAIT = 0;

-- The driver queues reports per handle. Undrained, a dead pad looks alive while its
-- backlog is worked through.
local DRAIN_LIMIT = 64;

-- DS4Windows, Steam Input and various launchers hold a device for a second or two at
-- startup. Without a retry that one failure disables the liveness check for the session.
local PROBE_RETRY_DELAY = 5.0;
local GENERIC_READ = 0x80000000;
local FILE_SHARE_READ_WRITE = 0x00000003;
local OPEN_EXISTING = 3;
local FILE_FLAG_OVERLAPPED = 0x40000000;

-- ReadFile says 997 and GetOverlappedResult says 996 for the same condition. Both mean
-- not finished, and treating 996 as an error gives up after one tick.
local ERROR_IO_INCOMPLETE = 996;
local ERROR_IO_PENDING = 997;

-- Classic Bluetooth HID. Windows keeps one of these nodes for as long as the pairing
-- exists, powered on or not, which is the entire reason the probe exists. LE nodes are
-- torn down properly and are trusted.
local BLUETOOTH_HID_PROFILE = '00001124';
local BLUETOOTH_LE_PROFILE = '00001812';
local INVALID_HANDLE_VALUE = ffi.cast('void*', -1);

local gamepadfix = T{
    lastCheckTime = 0,
    lastControllerState = nil,
    lastGamepadState = nil,
    inputManager = nil,
    verbose = false,
    pollCount = 0,
    gamepadStateAtLoad = nil,
    lastFailure = nil,
};

local function log(text)
    print(chat.header(addon.name):append(chat.message(text)));
end

-- The label plain and the value colored, which is the only shape log cannot do.
local function logValue(label, value)
    print(chat.header(addon.name):append(chat.message(label)):append(chat.success(value)));
end

-- includeIgnored returns the rejected devices too, which only the debug dump wants. A
-- rejected device comes back without its path, since nothing will probe it.
local function enumerateHidDevices(includeIgnored)
    local results = T{};

    if user32 == nil then
        return results, 'user32.dll failed to load';
    end

    local deviceCount = ffi.new('uint32_t[1]', 0);
    local entrySize = ffi.sizeof('RAWINPUTDEVICELIST');

    if user32.GetRawInputDeviceList(nil, deviceCount, entrySize) == API_FAILURE then
        return results, 'GetRawInputDeviceList failed on the count pass';
    end

    local total = tonumber(deviceCount[0]);
    if total == nil or total == 0 then
        return results, 'Windows reported 0 input devices';
    end

    local devices = ffi.new('RAWINPUTDEVICELIST[?]', total);
    local written = user32.GetRawInputDeviceList(devices, deviceCount, entrySize);
    if written == API_FAILURE then
        return results, 'GetRawInputDeviceList failed on the fill pass';
    end

    local info = ffi.new('RID_DEVICE_INFO');
    local infoSize = ffi.new('uint32_t[1]');
    local nameBuffer = ffi.new('char[?]', NAME_BUFFER_SIZE);
    local nameSize = ffi.new('uint32_t[1]');

    for i = 0, written - 1 do
        if devices[i].dwType == RIM_TYPEHID then
            info.cbSize = ffi.sizeof('RID_DEVICE_INFO');
            infoSize[0] = info.cbSize;

            if user32.GetRawInputDeviceInfoA(devices[i].hDevice, RIDI_DEVICEINFO, info, infoSize) ~= API_FAILURE then
                local usagePage = tonumber(info.u.hid.usUsagePage);
                local usage = tonumber(info.u.hid.usUsage);
                local counts = (usagePage == USAGE_PAGE_GENERIC_DESKTOP
                    and (usage == USAGE_GAMEPAD or usage == USAGE_JOYSTICK));

                if counts or includeIgnored then
                    local path = nil;

                    if counts then
                        nameSize[0] = NAME_BUFFER_SIZE;
                        if user32.GetRawInputDeviceInfoA(devices[i].hDevice, RIDI_DEVICENAME, nameBuffer, nameSize) ~= API_FAILURE then
                            path = ffi.string(nameBuffer);
                        end
                    end

                    results:append(T{
                        vid = tonumber(info.u.hid.dwVendorId),
                        pid = tonumber(info.u.hid.dwProductId),
                        usagePage = usagePage,
                        usage = usage,
                        counts = counts,
                        path = path,
                    });
                end
            end
        end
    end

    return results, nil;
end

local probes = {};
local transferred = ffi.new('uint32_t[1]');

--[[ The driver writes into the buffer asynchronously, so freeing it with a read still
     outstanding is a write into freed memory. CloseHandle requests cancellation but does
     not promise the read has finished, so the wait is taken either way. It cannot hang:
     on the failed path the handle is already closed, which completes the read. ]]
local function closeProbe(probe)
    if probe.handle ~= nil then
        local cancelled = probe.pending and kernel32.CancelIoEx(probe.handle, nil) ~= 0;

        if cancelled then
            kernel32.GetOverlappedResult(probe.handle, probe.overlapped, transferred, WAIT);
        end

        kernel32.CloseHandle(probe.handle);

        if probe.pending and not cancelled then
            kernel32.GetOverlappedResult(probe.handle, probe.overlapped, transferred, WAIT);
        end
    end

    if probe.event ~= nil then
        kernel32.CloseHandle(probe.event);
    end

    probe.handle = nil;
    probe.event = nil;
    probe.buffer = nil;
    probe.overlapped = nil;
    probe.pending = false;
end

local function releaseProbes()
    for path, probe in pairs(probes) do
        closeProbe(probe);
        probes[path] = nil;
    end
end

--[[ Every failure path returns a probe marked unprobeable, which counts as present.
     Wrongly believing a pad is there costs the hitching this addon removes; wrongly
     believing one is absent switches the gamepad off under a player holding it.

     Share read and write with read access only, so each handle gets its own copy of
     every report and nothing is taken from the game. ]]
local function openProbe(path, now)
    local probe = { unprobeable = true, unprobeableSince = now, lastSeen = now, everReported = false, pending = false };

    if kernel32 == nil then
        return probe;
    end

    local handle = kernel32.CreateFileA(path, GENERIC_READ, FILE_SHARE_READ_WRITE, nil,
        OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nil);

    if handle == nil or handle == INVALID_HANDLE_VALUE then
        return probe;
    end

    -- Manual reset, or the event clears out from under GetOverlappedResult.
    local event = kernel32.CreateEventA(nil, EVENT_MANUAL_RESET, EVENT_START_UNSIGNALLED, nil);
    if event == nil then
        kernel32.CloseHandle(handle);
        return probe;
    end

    probe.handle = handle;
    probe.event = event;
    probe.buffer = ffi.new('uint8_t[?]', READ_SIZE);
    probe.overlapped = ffi.new('GPF_OVERLAPPED[1]');
    probe.overlapped[0].hEvent = event;
    probe.unprobeable = false;
    probe.unprobeableSince = nil;

    return probe;
end

-- The read must never block. A synchronous read against a powered off pad never returns,
-- and this is the render thread.
local function issueRead(probe)
    probe.overlapped[0].Internal = 0;
    probe.overlapped[0].InternalHigh = 0;
    probe.overlapped[0].Offset = 0;
    probe.overlapped[0].OffsetHigh = 0;

    if kernel32.ReadFile(probe.handle, probe.buffer, READ_SIZE, nil, probe.overlapped) ~= 0 then
        return true;
    end

    if kernel32.GetLastError() == ERROR_IO_PENDING then
        probe.pending = true;
    else
        probe.unprobeable = true;
    end

    return false;
end

local function recordReport(probe, now)
    probe.lastSeen = now;
    probe.everReported = true;
end

-- NO_WAIT, so an unfinished read reports incomplete and we come back next tick.
local function pumpProbe(probe, now)
    for _ = 1, DRAIN_LIMIT do
        if probe.pending then
            if kernel32.GetOverlappedResult(probe.handle, probe.overlapped, transferred, NO_WAIT) == 0 then
                local err = kernel32.GetLastError();
                if err ~= ERROR_IO_INCOMPLETE and err ~= ERROR_IO_PENDING then
                    probe.unprobeable = true;
                    probe.unprobeableSince = now;
                end
                return;
            end

            probe.pending = false;
            recordReport(probe, now);
        elseif issueRead(probe) then
            recordReport(probe, now);
        else
            if (probe.unprobeable) then
                probe.unprobeableSince = now;
            end

            return;
        end
    end
end

-- A device that could not be opened is always alive, which is the safe direction.
local function probeIsAlive(probe, now)
    if probe.unprobeable then
        return true;
    end

    local limit = probe.everReported and LIVENESS_TIMEOUT or UNPROVEN_TIMEOUT;
    return (now - probe.lastSeen) < limit;
end

--[[ Keyed on the transport in the path, not on a vendor or product id, so a new pad
     needs no maintenance. Pads differ in what silence means: some stream continuously,
     others speak only on change and are legitimately quiet. Silence is evidence of
     absence only for the transport that keeps a node alive after the pad is off. ]]
local function needsLivenessCheck(path)
    return path:find(BLUETOOTH_HID_PROFILE, 1, true) ~= nil;
end

local function transportName(path)
    if path == nil then
        return 'unknown';
    end

    if path:find(BLUETOOTH_HID_PROFILE, 1, true) then
        return 'bluetooth';
    end

    if path:find(BLUETOOTH_LE_PROFILE, 1, true) then
        return 'bluetooth le';
    end

    return 'usb';
end

-- Also drops probes for devices gone from the list, so a pad that disappears cleanly
-- leaves nothing behind.
local function hasRawInputController()
    local now = os.clock();
    local devices, failure = enumerateHidDevices(false);

    --[[ An enumeration that failed is not an enumeration that found nothing. The fill
         pass returns an insufficient buffer error when a device appears between the two
         passes, which is exactly when a controller is being connected, so trusting the
         empty list would disable the pad at the moment it arrives. Every other failure
         path here assumes present, and this is the one that reached the caller. ]]
    if (failure ~= nil) then
        gamepadfix.lastFailure = failure;
        return true;
    end

    gamepadfix.lastFailure = nil;

    local seen = {};
    local alive = false;

    for _, device in ipairs(devices) do
        device.transport = transportName(device.path);

        if device.path == nil or not needsLivenessCheck(device.path) then
            device.trusted = true;
            alive = true;
        else
            seen[device.path] = true;

            local probe = probes[device.path];
            if probe == nil then
                probe = openProbe(device.path, now);
                probes[device.path] = probe;
            elseif probe.unprobeable and (now - (probe.unprobeableSince or now)) >= PROBE_RETRY_DELAY then
                -- Whatever was holding the device may have let go by now.
                closeProbe(probe);
                probe = openProbe(device.path, now);
                probes[device.path] = probe;
            end

            if not probe.unprobeable then
                pumpProbe(probe, now);
            end

            device.silentFor = now - probe.lastSeen;
            device.alive = probeIsAlive(probe, now);
            device.unprobeable = probe.unprobeable;
            device.everReported = probe.everReported;

            if device.alive then
                alive = true;
            end
        end
    end

    for path, probe in pairs(probes) do
        if not seen[path] then
            closeProbe(probe);
            probes[path] = nil;
        end
    end

    gamepadfix.lastDevices = devices;

    return alive;
end

local function hasXInputController()
    if xinput == nil then
        return false;
    end

    local state = ffi.new('XINPUT_STATE');
    for i = 0, XUSER_MAX_COUNT - 1 do
        if xinput.XInputGetState(i, state) == ERROR_SUCCESS then
            return true;
        end
    end

    return false;
end

-- A second opinion, not the primary check. XInput cannot see a PlayStation pad at all,
-- so it can only turn a no into a yes. The or short circuits, so it usually costs nothing.
local function checkControllerPresence()
    return hasRawInputController() or hasXInputController();
end

local function surveyXInputSlots()
    local results = T{};

    if xinput == nil then
        return results, 'no xinput dll could be loaded';
    end

    local state = ffi.new('XINPUT_STATE');
    for i = 0, XUSER_MAX_COUNT - 1 do
        local code = tonumber(xinput.XInputGetState(i, state));
        local meaning = 'error';
        if code == ERROR_SUCCESS then
            meaning = 'CONNECTED';
        elseif code == ERROR_DEVICE_NOT_CONNECTED then
            meaning = 'empty';
        end
        results:append(T{ slot = i, code = code, meaning = meaning });
    end

    return results, nil;
end

local function getInputManager()
    if gamepadfix.inputManager == nil then
        gamepadfix.inputManager = AshitaCore:GetInputManager();
    end

    return gamepadfix.inputManager;
end

--[[ Announcements are suppressed during the settling window after load, because a
     stalled pad reads as present for its first few seconds and would otherwise announce
     a disconnect on every launch. The setting is still acted on meanwhile, and
     lastControllerState stays nil so the first real message means something changed. ]]
local function monitorGamepad()
    local inputMgr = getInputManager();
    if inputMgr == nil then
        return;
    end

    local controllerPresent = checkControllerPresence();
    local gamepadDisabled = inputMgr:GetDisableGamepad();
    local gamepadStateChanged = false;

    if controllerPresent and gamepadDisabled then
        inputMgr:SetDisableGamepad(false);
        gamepadDisabled = false;
        gamepadStateChanged = true;
    elseif not controllerPresent and not gamepadDisabled then
        inputMgr:SetDisableGamepad(true);
        gamepadDisabled = true;
        gamepadStateChanged = true;
    end

    local settling = gamepadfix.settleAt ~= nil and os.clock() < gamepadfix.settleAt;

    if settling then
        gamepadfix.lastGamepadState = gamepadDisabled;
        if gamepadfix.verbose then
            log(string.format('poll %d: settling, controller=%s gamepadDisabled=%s',
                gamepadfix.pollCount, tostring(controllerPresent), tostring(gamepadDisabled)));
        end
        return;
    end

    gamepadfix.settleAt = nil;

    if gamepadfix.lastControllerState ~= nil and controllerPresent ~= gamepadfix.lastControllerState then
        log(controllerPresent and 'Controller connected.' or 'Controller disconnected.');
    end

    gamepadfix.lastControllerState = controllerPresent;

    if gamepadfix.lastGamepadState ~= nil and gamepadDisabled ~= gamepadfix.lastGamepadState and not gamepadStateChanged then
        log(gamepadDisabled and 'Gamepad disabled.' or 'Gamepad enabled.');
    end

    gamepadfix.lastGamepadState = gamepadDisabled;

    if gamepadfix.verbose then
        local action = 'none';
        if gamepadStateChanged then
            action = gamepadDisabled and 'we disabled gamepad' or 'we enabled gamepad';
        end
        log(string.format('poll %d: controller=%s gamepadDisabled=%s action=%s',
            gamepadfix.pollCount,
            tostring(controllerPresent),
            tostring(gamepadDisabled),
            action));
    end
end

local function describeDevice(device)
    if device.trusted then
        return 'present, trusted without probing';
    end

    if device.unprobeable then
        return 'present, could not open it to check';
    end

    if device.alive then
        return string.format('present, last input %.1fs ago', device.silentFor or 0);
    end

    return string.format('ABSENT, silent %.1fs, limit %.0fs%s',
        device.silentFor or 0,
        device.everReported and LIVENESS_TIMEOUT or UNPROVEN_TIMEOUT,
        device.everReported and '' or ', never reported');
end

-- The only diagnostic that reaches hardware nobody here owns, so it ships. It costs
-- nothing until somebody types it.
local function print_debug(showIgnored)
    log(string.format('---- gamepadfix %s ----', addon.version));

    if gamepadfix.lastFailure ~= nil then
        log(string.format('enumeration failed: %s   (assuming a controller is present)', gamepadfix.lastFailure));
    end

    local inputMgr = getInputManager();
    if inputMgr == nil then
        log('gamepad: INPUT MANAGER UNAVAILABLE, the addon cannot work at all');
    else
        log(string.format('gamepad: %s   (%s when the addon loaded)   polls: %d',
            inputMgr:GetDisableGamepad() and 'DISABLED' or 'ENABLED',
            gamepadfix.gamepadStateAtLoad and 'disabled' or 'enabled',
            gamepadfix.pollCount));
    end

    local verdict = checkControllerPresence();
    local watched = gamepadfix.lastDevices or T{};

    log(string.format('controllers: %d found, verdict %s',
        #watched, verdict and 'PRESENT' or 'NONE'));

    for _, d in ipairs(watched) do
        log(string.format('  %04x:%04x  %-13s %s',
            d.vid, d.pid, d.transport or 'unknown', describeDevice(d)));
    end

    local slots, xerr = surveyXInputSlots();
    if xerr ~= nil then
        log('xinput: ' .. xerr);
    else
        local connected = '';
        for _, s in ipairs(slots) do
            if s.meaning == 'CONNECTED' then
                connected = (connected == '') and tostring(s.slot) or (connected .. ', ' .. s.slot);
            end
        end
        log(connected == '' and 'xinput: all four slots empty'
            or ('xinput: slot ' .. connected .. ' connected'));
    end

    local all, rerr = enumerateHidDevices(true);
    if rerr ~= nil then
        log('hid: ' .. rerr);
        return;
    end

    local ignored = 0;
    for _, d in ipairs(all) do
        if not d.counts then
            ignored = ignored + 1;
        end
    end

    if not showIgnored then
        log(string.format('%d other hid devices ignored, /gamepadfix debug all to list them', ignored));
        return;
    end

    log(string.format('%d other hid devices ignored:', ignored));
    for _, d in ipairs(all) do
        if not d.counts then
            log(string.format('  %04x:%04x  page %02x usage %02x', d.vid, d.pid, d.usagePage, d.usage));
        end
    end
end

local function print_status()
    local inputMgr = getInputManager();

    log('Status:');

    if inputMgr then
        logValue('  Gamepad: ', inputMgr:GetDisableGamepad() and 'Disabled' or 'Enabled');
    end

    logValue('  Controller: ', checkControllerPresence() and 'Connected' or 'Not Connected');
end

ashita.events.register('load', 'load_cb', function ()
    local inputMgr = getInputManager();
    if inputMgr then
        gamepadfix.lastGamepadState = inputMgr:GetDisableGamepad();
        gamepadfix.gamepadStateAtLoad = gamepadfix.lastGamepadState;
    end

    -- Seeded from the real state, so the first poll is not read as a change.
    checkControllerPresence();
    gamepadfix.settleAt = os.clock() + UNPROVEN_TIMEOUT;
end);

ashita.events.register('unload', 'unload_cb', function ()
    -- The gamepad setting is left as it is. Detection is trusted, so a disabled gamepad
    -- on unload means there genuinely was no controller.
    releaseProbes();
end);

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or args[1]:lower() ~= '/gamepadfix') then
        return;
    end

    e.blocked = true;

    local sub = (#args >= 2) and args[2]:lower() or '';

    if sub == 'debug' then
        print_debug(#args >= 3 and args[3]:lower() == 'all');
    elseif sub == 'verbose' then
        gamepadfix.verbose = not gamepadfix.verbose;
        log(string.format('verbose logging %s', gamepadfix.verbose and 'ON, one line per second' or 'OFF'));
    elseif sub == 'on' then
        -- Diagnostic only. The next poll undoes it, and the message says so.
        local inputMgr = getInputManager();
        if inputMgr then
            inputMgr:SetDisableGamepad(false);
            gamepadfix.lastGamepadState = false;
            log(string.format('forced gamepad ON. Note the addon will undo this within %g second(s) if it sees no controller.', CHECK_INTERVAL));
        end
    else
        print_status();
    end
end);

ashita.events.register('d3d_present', 'present_cb', function ()
    -- Polling faster buys nothing. How long Windows takes to add or remove the device
    -- dominates, and that has been seen approaching a minute on some pads.
    local currentTime = os.clock();

    if (currentTime - gamepadfix.lastCheckTime) >= CHECK_INTERVAL then
        gamepadfix.lastCheckTime = currentTime;
        gamepadfix.pollCount = gamepadfix.pollCount + 1;
        monitorGamepad();
    end
end);
