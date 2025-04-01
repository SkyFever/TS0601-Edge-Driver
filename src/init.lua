-- Zigbee PC Remote Switch Edge Driver
-- Copyright 2025 YeongGeun Cha (SkyFever)
--
-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
-- This driver is based on techniques from ST-Edge-Driver by iquix
-- https://github.com/iquix/ST-Edge-Driver

local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local zcl_clusters = require "st.zigbee.zcl.clusters"
local zcl_messages = require "st.zigbee.zcl"
local messages = require "st.zigbee.messages"
local data_types = require "st.zigbee.data_types"
local zb_const = require "st.zigbee.constants"
local generic_body = require "st.zigbee.generic_body"
local log = require "log"

-- Device Fingerprints
local TUYA_PC_REMOTE_SWITCH_FINGERPRINTS = {
  { model = "TS0601", mfr = "_TZE204_6fk3gewc" }
}

-- Tuya DP (Data Points)
local CLUSTER_TUYA = 0xEF00
local SET_DATA = 0x00
local TUYA_SET_DATA_RESPONSE = 0x01
local TUYA_SEND_DATA_REQUEST = 0x02
local TUYA_STATE_CHANGE = 0x04
local TUYA_SET_TIME = 0x24

-- Tuya DP Types
local DP_TYPE_BOOL = "\x01"
local DP_TYPE_VALUE = "\x02"
local DP_TYPE_ENUM = "\x04"

-- Tuya DP IDs
local DP_SWITCH = "\x01"            -- Main Switch (PC Power) - 1 (0x01)
local DP_MODE_RESET = "\x65"        -- Mode Reset (Soft or Force) - 101 (0x65) (Type 4, Value 0: Hard-reset, Valde 1: Soft-reset)
local DP_RF_REMOTE = "\x66"         -- RF Remote - 102 (0x66) (Unused & Untested)
local DP_RF_STUDY = "\x67"          -- RF Train - 103 (0x67) (Unused & Untested)
local DP_BUZZER = "\x68"            -- Buzzer Sound ON/OFF - 104 (0x68)
local DP_RELAY_STATUS = "\x69"      -- Relay Status - 105 (0x69) (Untested)
local DP_CHILD_LOCK = "\x6A"        -- Child Lock - 106 (0x6A)

-- Component IDs
local COMPONENT_MAIN = "main"
local COMPONENT_MODE_RESET = "mode_reset"
local COMPONENT_BUZZER = "buzzer"
local COMPONENT_RELAY_STATUS = "relay_status"
local COMPONENT_CHILD_LOCK = "child_lock"
local COMPONENT_DP_TEST = "dpTest"  -- DP Test Component (Unused)

-- DP ID with Component Mapping
local DP_TO_COMPONENT_MAP = {
  [DP_SWITCH] = COMPONENT_MAIN,
  [DP_MODE_RESET] = COMPONENT_MODE_RESET,
  [DP_BUZZER] = COMPONENT_BUZZER,
  [DP_RELAY_STATUS] = COMPONENT_RELAY_STATUS,
  [DP_CHILD_LOCK] = COMPONENT_CHILD_LOCK
}

-- Component Type Mapping(for UI)
local COMPONENT_TYPE_MAP = {
  [COMPONENT_MAIN] = "switch",
  [COMPONENT_MODE_RESET] = "momentary",
  [COMPONENT_BUZZER] = "switch",
  [COMPONENT_RELAY_STATUS] = "switch",
  [COMPONENT_CHILD_LOCK] = "switch",
  [COMPONENT_DP_TEST] = "momentary" -- DP Test Component (Unused)
}

-- Packet ID for Tuya commands
local packet_id = 0

-- Debugging utility function
local function dump_message(message)
  if not message then
    log.error("Message is nil")
    return "nil"
  end
  
  if type(message) ~= "table" then
    return tostring(message)
  end
  
  local result = "{"
  for k, v in pairs(message) do
    if type(v) == "table" then
      result = result .. k .. "=" .. dump_message(v) .. ", "
    else
      result = result .. k .. "=" .. tostring(v) .. ", "
    end
  end
  result = result .. "}"
  return result
end

-- Bytes to Hexadecimal String Conversion
local function bytes_to_hex(bytes)
  if not bytes then return "nil" end
  local hex = ""
  for i = 1, #bytes do
    hex = hex .. string.format("%02X", string.byte(bytes, i))
  end
  return hex
end

-- Safe String Formatting
local function safe_format(format_str, ...)
  local args = {...}
  local success, result = pcall(function()
    return string.format(format_str, table.unpack(args))
  end)
  
  if success then
    return result
  else
    -- If formatting fails, return a fallback string
    local fallback = "Format error: " .. format_str
    for i, arg in ipairs(args) do
      fallback = fallback .. " [arg" .. i .. "=" .. tostring(arg) .. "]"
    end
    return fallback
  end
end

-- Tuya Command Sending Function
local function send_tuya_command(device, dp, dp_type, fncmd) 
  log.info(safe_format("Sending Tuya command - DP: %s, DP Type: %s, Value: %s", 
    bytes_to_hex(dp), bytes_to_hex(dp_type), bytes_to_hex(fncmd)))
  
  -- Generate ZCL Header
  local zclh = zcl_messages.ZclHeader({cmd = data_types.ZCLCommandId(SET_DATA)})
  zclh.frame_ctrl:set_cluster_specific()
  zclh.frame_ctrl:set_disable_default_response()
  
  -- Generate Address Header
  local addrh = messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(CLUSTER_TUYA),
    zb_const.HA_PROFILE_ID,
    CLUSTER_TUYA
  )
  
  -- Increment Packet ID
  packet_id = (packet_id + 1) % 65536
  
  -- Generate Payload Body
  local fncmd_len = string.len(fncmd)
  local payload_body = generic_body.GenericBody(string.pack(">I2", packet_id) .. dp .. dp_type .. string.pack(">I2", fncmd_len) .. fncmd)
  
  -- Generate ZCL Message Body
  local message_body = zcl_messages.ZclMessageBody({
    zcl_header = zclh,
    zcl_body = payload_body
  })
  
  -- Generate Zigbee Message
  local send_message = messages.ZigbeeMessageTx({
    address_header = addrh,
    body = message_body
  })
  
  -- Try sending the message
  local success, err = pcall(function()
    device:send(send_message)
  end)
  
  if not success then
    log.error(safe_format("Failed to send Tuya command: %s", err))
    return false
  end
  
  return true
end

-- Function to request device status
local function request_device_status(device)
  log.info("===== Requesting device status =====")
  
  -- Configure Data structure for TUYA Protocol
  local zclh = zcl_messages.ZclHeader({cmd = data_types.ZCLCommandId(TUYA_SEND_DATA_REQUEST)})
  zclh.frame_ctrl:set_cluster_specific()
  zclh.frame_ctrl:set_disable_default_response()
  
  local addrh = messages.AddressHeader(
    zb_const.HUB.ADDR,
    zb_const.HUB.ENDPOINT,
    device:get_short_address(),
    device:get_endpoint(CLUSTER_TUYA),
    zb_const.HA_PROFILE_ID,
    CLUSTER_TUYA
  )
  
  packet_id = (packet_id + 1) % 65536
  local payload_body = generic_body.GenericBody(string.pack(">I2", packet_id))
  
  local message_body = zcl_messages.ZclMessageBody({
    zcl_header = zclh,
    zcl_body = payload_body
  })
  
  local send_message = messages.ZigbeeMessageTx({
    address_header = addrh,
    body = message_body
  })
  
  -- Try sending the message
  local success, err = pcall(function()
    device:send(send_message)
  end)
  
  if not success then
    log.error(safe_format("Failed to request device status: %s", err))
    return false
  end
  
  log.info("===== Device status request sent =====")
  return true
end

-- Device Initialization Handler
local function device_init(driver, device)
  log.info("===== Initializing PC Remote Switch device =====")
  log.info(safe_format("Device ID: %s", device.id))
  log.info(safe_format("Device Model: %s", device:get_model()))
  log.info(safe_format("Device Manufacturer: %s", device:get_manufacturer()))
  
  device:set_field("zigbee_fingerprints", TUYA_PC_REMOTE_SWITCH_FINGERPRINTS)
  
  -- Initialize device state
  device:emit_event(capabilities.switch.switch.off())
  
  -- Initialize each component
  for dp, component_id in pairs(DP_TO_COMPONENT_MAP) do
    if component_id ~= COMPONENT_MAIN and device.profile.components[component_id] then
      local component_type = COMPONENT_TYPE_MAP[component_id]
      if component_type == "switch" then
        device:emit_component_event(
          device.profile.components[component_id],
          capabilities.switch.switch.off()
        )
      end
    end
  end
  
  -- Request device status (initial state synchronization)
  device.thread:call_with_delay(1, function(d)
    request_device_status(device)
  end)
  
  log.info("===== Device initialization complete =====")
end

-- Device Addition Handler
local function device_added(driver, device)
  log.info("===== Device added =====")
  log.info(safe_format("Device ID: %s", device.id))
  log.info(safe_format("Device Model: %s", device:get_model()))
  log.info(safe_format("Device Manufacturer: %s", device:get_manufacturer()))
  
  -- Initialize device state
  device:emit_event(capabilities.switch.switch.off())
  
  -- Initialize each component
  for dp, component_id in pairs(DP_TO_COMPONENT_MAP) do
    if component_id ~= COMPONENT_MAIN and device.profile.components[component_id] then
      local component_type = COMPONENT_TYPE_MAP[component_id]
      if component_type == "switch" then
        device:emit_component_event(
          device.profile.components[component_id],
          capabilities.switch.switch.off()
        )
      end
    end
  end
  
  -- Request device status (initial state synchronization)
  device.thread:call_with_delay(2, function(d)
    request_device_status(device)
  end)
  
  log.info("===== Device addition complete =====")
end

-- Device Info Changed Handler
local function device_info_changed(driver, device, event, args)
  log.debug("===== Device info changed =====")
  
  -- Logging device information
  if event then
    log.debug(safe_format("Event type: %s", type(event)))
    if type(event) == "string" then
      log.debug(safe_format("Event: %s", event))
    elseif type(event) == "table" then
      log.debug(safe_format("Event: %s", dump_message(event)))
    end
  end
  
  -- Logging arguments
  if args then
    log.debug(safe_format("Args type: %s", type(args)))
    if type(args) == "table" then
      log.debug(safe_format("Args: %s", dump_message(args)))
    end
  end
  
  -- Request device status (initial state synchronization)
  device.thread:call_with_delay(1, function(d)
    request_device_status(device)
  end)
end

-- Tuya Data receive Handler
local function tuya_cluster_handler(driver, device, zb_rx)
  log.info("===== Received Tuya data =====")
  
  -- Tuya Data Processing
  if not zb_rx.body or not zb_rx.body.zcl_body then
    log.error("No ZCL body in the received message")
    return
  end
  
  -- Parse Tuya Protocol
  local rx = zb_rx.body.zcl_body.body_bytes
  if not rx or #rx < 7 then
    log.error("Invalid Tuya payload length")
    return
  end
  
  -- Payload structure:
  -- 0-1: Packet ID (2 bytes)
  -- 2: DP ID
  -- 3: DP Type
  -- 4-5: Data Length (Big Endian)
  -- 6+: Data Value
  
  local dp = rx:sub(3,3)
  local dp_type = rx:sub(4,4)
  local fncmd_len = string.unpack(">I2", rx:sub(5,6))
  local fncmd = rx:sub(7, 7 + fncmd_len - 1)
  
  -- Print debug information
  log.info(safe_format("DP: %s, DP Type: %s, Value: %s", 
    bytes_to_hex(dp), bytes_to_hex(dp_type), bytes_to_hex(fncmd)))
  
  -- DP ID
  local component_id = DP_TO_COMPONENT_MAP[dp]
  
  if component_id then
    -- Check Component Type
    local component_type = COMPONENT_TYPE_MAP[component_id]
    log.info(safe_format("Processing state for component: %s (type: %s)", component_id, component_type))
    
    if dp_type == DP_TYPE_BOOL then
      local switch_state = string.byte(fncmd, 1) == 1 and "on" or "off"
      log.info(safe_format("State for %s: %s", component_id, switch_state))
      
      -- 해당 컴포넌트에 이벤트 발생
      if component_type == "switch" then
        if component_id == COMPONENT_MAIN then
          device:emit_event(capabilities.switch.switch(switch_state))
        elseif device.profile.components[component_id] then
          device:emit_component_event(
            device.profile.components[component_id],
            capabilities.switch.switch(switch_state)
          )
        end
      end
    else
      log.error(safe_format("Invalid data for DP %s - Type: %s, Value: %s", 
        bytes_to_hex(dp), bytes_to_hex(dp_type), bytes_to_hex(fncmd)))
    end
  else
    log.warn(safe_format("Unhandled DP: %s", bytes_to_hex(dp)))
    -- Try to handle unknown DP
    log.info(safe_format("Unknown DP %s with value: %s", bytes_to_hex(dp), bytes_to_hex(fncmd)))
  end
  
  log.info("===== Tuya data processing complete =====")
end

-- Switch On Command Handler
local function handle_switch_on(driver, device, command)
  log.info("===== Handling switch on command =====")
  log.info(safe_format("Component: %s", command.component))
  
  -- DP ID
  local dp = DP_SWITCH -- Default Value
  
  -- Set DP ID based on component
  for dp_id, component in pairs(DP_TO_COMPONENT_MAP) do
    if component == command.component then
      dp = dp_id
      break
    end
  end
  
  -- Send Switch On command in Tuya format
  local fncmd = "\x01" -- 1 = On
  
  -- Send command
  local success = send_tuya_command(device, dp, DP_TYPE_BOOL, fncmd)
  
  -- Update state
  if success then
    if command.component == COMPONENT_MAIN then
      device:emit_event(capabilities.switch.switch.on())
    else
      local component = device.profile.components[command.component]
      if component then
        device:emit_component_event(component, capabilities.switch.switch.on())
      end
    end
  end
  
  log.info("===== Switch on command sent =====")
end

-- Switch Off Command Handler
local function handle_switch_off(driver, device, command)
  log.info("===== Handling switch off command =====")
  log.info(safe_format("Component: %s", command.component))
  
  -- DP ID
  local dp = DP_SWITCH -- Default Value
  
  -- Set DP ID based on component
  for dp_id, component in pairs(DP_TO_COMPONENT_MAP) do
    if component == command.component then
      dp = dp_id
      break
    end
  end
  
  -- Send Switch Off command in Tuya format
  local fncmd = "\x00" -- 0 = Off
  
  -- Send command
  local success = send_tuya_command(device, dp, DP_TYPE_BOOL, fncmd)
  
  -- Update state
  if success then
    if command.component == COMPONENT_MAIN then
      device:emit_event(capabilities.switch.switch.off())
    else
      local component = device.profile.components[command.component]
      if component then
        device:emit_component_event(component, capabilities.switch.switch.off())
      end
    end
  end
  
  log.info("===== Switch off command sent =====")
end

-- Command to handle reset action
local function handle_reset_action(device, reset_type)
  log.info(safe_format("===== Run Reset Command: %s =====", reset_type))
  
  local dp
  local dp_type
  local value
  
  if reset_type == "reset" then
    dp = "\x65"  -- DP_MODE_RESET
    dp_type = "\x04"  -- DP_TYPE_ENUM
    value = "\x01"  -- SOFT_RESET
    log.info("Restart PC")
  elseif reset_type == "force_restart" then
    dp = "\x65"  -- DP_MODE_RESET
    dp_type = "\x04"  -- DP_TYPE_ENUM
    value = "\x00"  -- FORCE_RESET
    log.info("Force Restart PC")
  else
    log.error("Unknown Type: " .. reset_type)
    return false
  end
  
  log.info(safe_format("Send Command - DP ID: %d, Type: %s, Value: %d", 
  dp, bytes_to_hex(dp_type), value))

  -- Send command
  local success = send_tuya_command(device, dp, dp_type, value)
  
  if success then
    log.info("Successfully sent reset command")
  else
    log.error("Failed to send reset command")
  end
  
  return success
end

-- Momentary Push Command Handler
local function handle_momentary_push(driver, device, command)
  log.info("===== Handling momentary push command =====")
  log.info(safe_format("Component: %s", command.component))

  if command.component == COMPONENT_DP_TEST then
    -- Values from preferences
    local test_dp_id = device.preferences.testDpId
    local test_dp_type = device.preferences.testDpType
    local test_dp_value = device.preferences.testDpValue
    
    if not test_dp_id or test_dp_id < 1 or test_dp_id > 255 then
      log.error("Invalid Test DP ID: " .. (test_dp_id or "nil"))
      return
    end
    
    if not test_dp_type then test_dp_type = DP_TYPE_BOOL end
    if not test_dp_value then test_dp_value = 1 end
    
    log.info(safe_format("Sending test command - DP ID: %d, Type: %d, Value: %d", test_dp_id, test_dp_type, test_dp_value))
    
    -- Convert DP ID to char
    local dp_char = string.char(test_dp_id)

    -- Convert DP Value to char
    local value_char = string.char(test_dp_value)

    -- Convert DP Type to char
    local dp_type_char = string.char(test_dp_type)
    
    -- Send command
    local success = send_tuya_command(device, dp_char, dp_type_char, value_char)
    
    if success then
      log.info("Test command sent successfully!")
    else
      log.error("Failed to send test command")
    end
    
    return
  end

  -- Check if the component is for reset action
  if command.component == COMPONENT_MODE_RESET then
    local reset_mode = device.preferences.resetMode or "reset"
    return handle_reset_action(device, reset_mode)
  end
  
  log.info("===== Momentary push command sent =====")
end

-- Device Refresh Command Handler
local function handle_refresh(driver, device, command)
  log.info("===== Handling refresh command =====")
  
  -- Request device status
  request_device_status(device)
  
  log.info("===== Refresh command sent =====")
end

-- Zigbee Message Handler
local function handle_all_zigbee_messages(driver, device, zb_rx)
  log.debug("===== Received Zigbee message =====")
  
  -- Address Header Info Logging
  if zb_rx and zb_rx.address_header then
    if zb_rx.address_header.profile_id then
      log.debug(safe_format("Profile ID: 0x%04X", zb_rx.address_header.profile_id))
    end
    
    if zb_rx.address_header.cluster_id then
      log.debug(safe_format("Cluster ID: 0x%04X", zb_rx.address_header.cluster_id))
    end
    
    if zb_rx.address_header.source_endpoint and zb_rx.address_header.source_endpoint.value then
      log.debug(safe_format("Source Endpoint: %d", zb_rx.address_header.source_endpoint.value))
    end
    
    if zb_rx.address_header.dest_endpoint and zb_rx.address_header.dest_endpoint.value then
      log.debug(safe_format("Destination Endpoint: %d", zb_rx.address_header.dest_endpoint.value))
    end
  end
  
  -- ZCL Header Info Logging
  if zb_rx and zb_rx.body and zb_rx.body.zcl_header then
    if zb_rx.body.zcl_header.cmd and zb_rx.body.zcl_header.cmd.value then
      log.debug(safe_format("ZCL Command ID: 0x%02X", zb_rx.body.zcl_header.cmd.value))
    end
    
    if zb_rx.body.zcl_header.frame_ctrl and zb_rx.body.zcl_header.frame_ctrl.value then
      log.debug(safe_format("ZCL Frame Type: 0x%02X", zb_rx.body.zcl_header.frame_ctrl.value))
    end
  end
end

-- Driver Configuration
local tuya_pc_remote_switch = ZigbeeDriver(
  "tuya-pc-remote-switch",
  {
    supported_capabilities = {
      capabilities.switch,
      capabilities.momentary,
      capabilities.refresh
    },
    zigbee_handlers = {
      cluster = {
        [CLUSTER_TUYA] = {
          [TUYA_SEND_DATA_REQUEST] = tuya_cluster_handler,
          [TUYA_SET_DATA_RESPONSE] = handle_all_zigbee_messages,
          [TUYA_STATE_CHANGE] = tuya_cluster_handler
        }
      },
      attr = {
        [zcl_clusters.Basic.ID] = {
          [zcl_clusters.Basic.attributes.ZCLVersion.ID] = handle_all_zigbee_messages,
          [zcl_clusters.Basic.attributes.ApplicationVersion.ID] = handle_all_zigbee_messages,
          [zcl_clusters.Basic.attributes.ModelIdentifier.ID] = handle_all_zigbee_messages,
          [zcl_clusters.Basic.attributes.PowerSource.ID] = handle_all_zigbee_messages
        }
      },
      fallback = handle_all_zigbee_messages
    },
    capability_handlers = {
      [capabilities.switch.ID] = {
        [capabilities.switch.commands.on.NAME] = handle_switch_on,
        [capabilities.switch.commands.off.NAME] = handle_switch_off
      },
      [capabilities.momentary.ID] = {
        [capabilities.momentary.commands.push.NAME] = handle_momentary_push
      },
      [capabilities.refresh.ID] = {
        [capabilities.refresh.commands.refresh.NAME] = handle_refresh
      }
    },
    lifecycle_handlers = {
      init = device_init,
      added = device_added,
      infoChanged = device_info_changed
    }
  }
)

tuya_pc_remote_switch:run()
