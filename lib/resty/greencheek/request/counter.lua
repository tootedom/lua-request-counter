-- Copyright [2018] [Dominic Tootell]

-- Licensed under the Apache License, Version 2.0 (the "License");
-- you may not use this file except in compliance with the License.
-- You may obtain a copy of the License at

--     http://www.apache.org/licenses/LICENSE-2.0

-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.

local ngx = require "ngx"
local cjson = require "cjson"
local shdict = require "resty.core.shdict"

local type = type
local assert = assert
local floor = math.floor
local null = ngx.null
local ngx_shared_dict = ngx.shared
local ngx_log = ngx.log
local ngx_warn = ngx.WARN
local ngx_err = ngx.ERR

local requests_shared_dict_default = 'request_counters'
local scale = 60
local expire_after_seconds = scale * 4

local FAILED_TO_SET_KEY_EXPIRY = "failed_set_key_expiry"


local _M = {
    _VERSION = "0.0.1",
}

local mt = {
    __index = _M
}

local function is_str(s)
    return type(s) == "string"
end

local function get_key(s)
    for i in string.gmatch(s, '([^_]+)') do
        return i
    end
end

--
-- Returns the current key and the previous key
-- based on the current nginx request time, and the scale.
-- key is <zone:key>_<epoch for period>
--
local function get_keys(key,start_of_period)
    return string.format("%s_%d",key,start_of_period),string.format("%s_%d_latency",key,start_of_period)
end

local function get_start_of_period(requesttime)
    local seconds = math.floor(requesttime)
    return (seconds - seconds%scale)
end

local function expire(premature, dict_name, requests_key,latency_key, expire_after_seconds)
    local dict = ngx_shared_dict[dict_name]

    local not_expired = true
    local expire_tries = 0
    local last_err = nil
    local retry = true

    while retry do
        expire_tries=expire_tries+1

        res, last_err = dict:expire(requests_key, expire_after_seconds)
        latency_res, latency_last_err = dict:expire(latency_key, expire_after_seconds+scale)

        if last_err == nil and latency_last_err == nil then
            not_expired = false
            retry = false
        else
            retry = expire_tries <= 2
            if retry then
                ngx_log(ngx_warn, '|{"level" : "WARN", "msg" : "' .. FAILED_TO_SET_KEY_EXPIRY .. '", "key": "' .. requests_key .. '", "retry" : "true" }|', last_err)
            else
                ngx_log(ngx_err, '|{"level" : "ERROR", "msg" : "' .. FAILED_TO_SET_KEY_EXPIRY .. '", "key": "' .. requests_key .. '", "retry" : "false" }|', last_err)
            end
        end

    end

    if not_expired then
        if is_str(last_err) then
            ngx_log(ngx_err,'|{"level" : "ERROR", "msg" : "' .. FAILED_TO_SET_KEY_EXPIRY .. '", "key": "' .. requests_key .. '" }|', last_err)
        else
            ngx_log(ngx_err,'|{"level" : "ERROR", "msg" : "' .. FAILED_TO_SET_KEY_EXPIRY .. '", "key": "' .. requests_key .. '" }|')
        end
    end

end

local function increment(dict_name,key,requesttime,starttime)


    local start_of_period = get_start_of_period(starttime)
    local requests_currrent_period_key, latency_current_period_key = get_keys(key,start_of_period)

    local dict = ngx_shared_dict[dict_name]
    local newval, err = dict:incr(requests_currrent_period_key,1,0)
    local success, err_latency  = dict:incr(latency_current_period_key,requesttime,0)

    if err == nil then
        if newval == 1 then
            ngx.timer.at(0, expire, dict_name, requests_currrent_period_key, latency_current_period_key, expire_after_seconds)
        end
    else
        ngx_log(ngx_err,'|{"level" : "ERROR", "msg" : "increment_requests_failure",  "incremented_counter" : "false", "key" : "' .. requests_currrent_period_key .. '"}|',err)
    end

end


function _M.record_generic_request(dict_name, latency_ms)
    increment(dict_name,"all",latency_ms,ngx.req.start_time())
end

function _M.record_specific_request(dict_name, key, latency_ms)
    increment(dict_name,key,latency_ms,ngx.req.start_time())
end


function _M.record_request(dict_name, key, latency_ms)
    increment(dict_name,key,latency_ms,ngx.req.start_time())
    increment(dict_name,"all",latency_ms,ngx.req.start_time())
end

local function starts_with(str, start)
    return str:sub(1, #start) == start
 end

local function get_stats(dict,key)
    local requests = dict:get(key)
    local latency  = 0
    if requests == nil then
        requests = 0
        latency = 0
    else
        latency = ((dict:get(string.format("%s_latency",key)))*1000)/requests
    end

    return requests,latency
end

local function generate_stats_dict(period,requests,latency)
    local stats = {
        ["startofminute_epoch"] = period,
        ["requests"] = requests,
        ["latency_ms"] = latency
    }
    return stats
end

local function get_current_rate(start_time, start_of_period,prev_requests,current_requests)
    local elapsed = start_time - start_of_period
    local current_rate = prev_requests * ( (scale - elapsed) / scale) + current_requests
    return current_rate
end

function _M.single_stats(dict_name,key)
    local dict = ngx_shared_dict[dict_name]
    local start_time = ngx.req.start_time()
    local start_of_period = get_start_of_period(start_time)
    local previous_period = start_of_period-scale
    local previous_but_one_period = previous_period-scale

    local current_requests, current_latency = get_stats(dict,string.format("%s_%d",key,start_of_period))
    local prev_requests, prev_latency = get_stats(dict,string.format("%s_%d",key,previous_period))
    local prev_but_one_requests, prev_but_one_latency = get_stats(dict,string.format("%s_%d",key,previous_but_one_period))

    local current_rate = get_current_rate(start_time, start_of_period,prev_requests,current_requests)
    local current_dict = generate_stats_dict(start_of_period,current_requests,current_latency)
    current_dict["rate"] = current_rate
    current_dict["epoch"] = math.floor(start_time)

    local json = cjson.encode({
        stats = {
            current = current_dict,
            prev1 = generate_stats_dict(previous_period,prev_requests,prev_latency),
            prev2 = generate_stats_dict(previous_but_one_period,prev_but_one_requests,prev_but_one_latency)
        },
        shared_dict_info = {
            free_space = dict:free_space(),
            capacity = dict:capacity()
        }
    })

    return json
end


function _M.stats(dict_name)
    local keys = {}
    local dict = ngx_shared_dict[dict_name]
    for i,key in pairs(dict:get_keys()) do
        keys[get_key(key)] = true
    end

    local start_time = ngx.req.start_time()
    local start_of_period = get_start_of_period(start_time)
    local previous_period = start_of_period-scale
    local previous_but_one_period = previous_period-scale

    local json = {}
    for key,v in pairs(keys) do
        local current_requests, current_latency = get_stats(dict,string.format("%s_%d",key,start_of_period))
        local prev_requests, prev_latency = get_stats(dict,string.format("%s_%d",key,previous_period))
        local prev_but_one_requests, prev_but_one_latency = get_stats(dict,string.format("%s_%d",key,previous_but_one_period))

        local current_rate = get_current_rate(start_time, start_of_period,prev_requests,current_requests)
        local current_dict = generate_stats_dict(start_of_period,current_requests,current_latency)
        current_dict["rate"] = current_rate
        current_dict["epoch"] = math.floor(start_time)
        json[key] = {
            current = current_dict,
            prev1 = generate_stats_dict(previous_period,prev_requests,prev_latency),
            prev2 = generate_stats_dict(previous_but_one_period,prev_but_one_requests,prev_but_one_latency)
        }
    end


    return cjson.encode({
        stats = json,
        shared_dict_info = {
            free_space = dict:free_space(),
            capacity = dict:capacity()
        }
    })
end

return _M

