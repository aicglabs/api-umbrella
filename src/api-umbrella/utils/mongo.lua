local cjson = require "cjson"
local http = require "resty.http"

local _M = {}

local function try_query(url, http_options)
  local httpc = http.new()
  local res, err = httpc:request_uri(url, http_options)
  if err then
    err = "mongodb query failed: " .. err
    return nil, err
  end

  if not res.body or res.headers["Content-Type"] ~= "application/json" then
    err = "mongodb unexpected response format: " .. (res.body or nil)
    return nil, err
  end

  local response = cjson.decode(res.body)
  if not response["success"] then
    err = "mongodb error"
    if response["error"] and response["error"]["name"] then
      err = err .. ": " .. response["error"]["name"]
    end
    return nil, err
  end

  return response
end

local function perform_query(path, query_options, http_options)
  if not query_options then
    query_options = {}
  end

  query_options["extended_json"] = "true"

  if type(query_options["query"]) == "table" then
    query_options["query"] = cjson.encode(query_options["query"])
  end

  if not http_options then
    http_options = {}
  end

  http_options["query"] = query_options

  local url = "http://127.0.0.1:" .. config["mora"]["port"] .. "/docs/api_umbrella/" .. config["mongodb"]["_database"] .. "/" .. path
  local response, err = try_query(url, http_options)

  -- If we get an "EOF" error from Mora, this means our query occurred during
  -- the middle of a server or replicaset change. In this case, retry the
  -- request one more time.
  --
  -- This should be less likely in mora since
  -- https://github.com/emicklei/mora/pull/29, but it's still possible for this
  -- to crop up if the socket gets closed sometime between the request starting
  -- and the query actually executing. After more research, this seems to be
  -- expected mgo behavior, and it's up to the app to handle these type of
  -- errors. I'm not entirely sure whether we should try to address the issue
  -- in mora itself, but in the meantime, we'll retry here.
  if err and err == "mongodb error: EOF" then
    response, err = try_query(url, http_options)
  end

  if err then
    return nil, err
  else
    return response
  end
end

function _M.find(collection, query_options)
  local response, err = perform_query(collection, query_options)

  local results = {}
  if not err and response and response["data"] then
    results = response["data"]
  end

  return results, err
end

function _M.first(collection, query_options)
  if not query_options then
    query_options = {}
  end

  query_options["limit"] = 1

  local results, err = _M.find(collection, query_options)

  local result
  if not err and results then
    result = results[1]
  end

  return result, err
end

function _M.update(collection, id, data)
  local http_options = {
    method = "PUT",
    headers = {
      ["Content-Type"] = "application/json",
    },
    body = cjson.encode(data),
  }

  return perform_query(collection .. "/" .. id, nil, http_options)
end

function _M.create(collection, data)
  local http_options = {
    method = "POST",
    headers = {
      ["Content-Type"] = "application/json",
    },
    body = cjson.encode(data),
  }

  return perform_query(collection, nil, http_options)
end

return _M
