# vim:set ft= ts=4 sw=4 et:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);
use Test::Nginx::Socket 'no_plan';

my $pwd = cwd();

our $HttpConfig = qq{
    lua_package_path "$pwd/lib/?.lua;/usr/local/openresty/lualib/resty/?.lua;;";
};

$ENV{TEST_NGINX_RESOLVER} = '8.8.8.8';
$ENV{TEST_NGINX_REDIS_PORT} ||= 6379;

no_long_string();
#no_diff();

run_tests();

__DATA__
=== TEST 1: Test generic stats
--- http_config eval
"
$::HttpConfig
lua_shared_dict request_counters 16k;
"
--- config
     log_by_lua_block {
        local request_counter = require "resty.greencheek.request.counter"

        local key = ngx.var.request_key
        if key ~= "stats" then
            if key == "" then
                request_counter.record_generic_request("request_counters",ngx.var.request_time)
            else
                request_counter.record_request("request_counters",key,ngx.var.request_time)
            end
        end
    }

    location /log {
        return 200;
    }

    location /all_only_stats {
        set $request_key "stats";

        content_by_lua_block {
            local request_counter = require "resty.greencheek.request.counter"

            ngx.say(request_counter.single_stats("request_counters","all"))
        }
    }
    
--- request eval
[ "GET /all_only_stats", "GET /all_only_stats","GET /log","GET /all_only_stats" ]
--- response_body_like eval
[ ".*requests\":0.*", ".*requests\":0.*","",".*requests\":1.*" ]
--- timeout: 600
