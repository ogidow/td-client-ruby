class TreasureData::API
module Job

  ####
  ## Job API
  ##

  # => [(jobId:String, type:Symbol, status:String, start_at:String, end_at:String, result_url:String)]
  def list_jobs(from=0, to=nil, status=nil, conditions=nil)
    params = {}
    params['from'] = from.to_s if from
    params['to'] = to.to_s if to
    params['status'] = status.to_s if status
    params.merge!(conditions) if conditions
    code, body, res = get("/v3/job/list", params)
    if code != "200"
      raise_error("List jobs failed", res)
    end
    js = checked_json(body, %w[jobs])
    result = []
    js['jobs'].each {|m|
      job_id = m['job_id']
      type = (m['type'] || '?').to_sym
      database = m['database']
      status = m['status']
      query = m['query']
      start_at = m['start_at']
      end_at = m['end_at']
      cpu_time = m['cpu_time']
      result_size = m['result_size'] # compressed result size in msgpack.gz format
      result_url = m['result']
      priority = m['priority']
      retry_limit = m['retry_limit']
      result << [job_id, type, status, query, start_at, end_at, cpu_time,
                 result_size, result_url, priority, retry_limit, nil, database]
    }
    return result
  end

  # => (type:Symbol, status:String, result:String, url:String, result:String)
  def show_job(job_id)
    # use v3/job/status instead of v3/job/show to poll finish of a job
    code, body, res = get("/v3/job/show/#{e job_id}")
    if code != "200"
      raise_error("Show job failed", res)
    end
    js = checked_json(body, %w[status])
    # TODO debug
    type = (js['type'] || '?').to_sym  # TODO
    database = js['database']
    query = js['query']
    status = js['status']
    debug = js['debug']
    url = js['url']
    start_at = js['start_at']
    end_at = js['end_at']
    cpu_time = js['cpu_time']
    result_size = js['result_size'] # compressed result size in msgpack.gz format
    result = js['result'] # result target URL
    hive_result_schema = (js['hive_result_schema'] || '')
    if hive_result_schema.empty?
      hive_result_schema = nil
    else
      begin
        hive_result_schema = JSON.parse(hive_result_schema)
      rescue JSON::ParserError => e
        # this is a workaround for a Known Limitation in the Pig Engine which does not set a default, auto-generated
        #   column name for anonymous columns (such as the ones that are generated from UDF like COUNT or SUM).
        # The schema will contain 'nil' for the name of those columns and that breaks the JSON parser since it violates
        #   the JSON syntax standard.
        if type == :pig and hive_result_schema !~ /[\{\}]/
          begin
            # NOTE: this works because a JSON 2 dimensional array is the same as a Ruby one.
            #   Any change in the format for the hive_result_schema output may cause a syntax error, in which case
            #   this lame attempt at fixing the problem will fail and we will be raising the original JSON exception
            hive_result_schema = eval(hive_result_schema)
          rescue SyntaxError => ignored_e
            raise e
          end
          hive_result_schema.each_with_index {|col_schema, idx|
            if col_schema[0].nil?
              col_schema[0] = "_col#{idx}"
            end
          }
        else
          raise e
        end
      end
    end
    priority = js['priority']
    retry_limit = js['retry_limit']
    return [type, query, status, url, debug, start_at, end_at, cpu_time,
            result_size, result, hive_result_schema, priority, retry_limit, nil, database]
  end

  def job_status(job_id)
    code, body, res = get("/v3/job/status/#{e job_id}")
    if code != "200"
      raise_error("Get job status failed", res)
    end

    js = checked_json(body, %w[status])
    return js['status']
  end

  def job_result(job_id)
    require 'msgpack'
    code, body, res = get("/v3/job/result/#{e job_id}", {'format'=>'msgpack'})
    if code != "200"
      raise_error("Get job result failed", res)
    end
    result = []
    MessagePack::Unpacker.new.feed_each(body) {|row|
      result << row
    }
    return result
  end

  # block is optional and must accept 1 parameter
  def job_result_format(job_id, format, io=nil, &block)
    if io
      code, body, res = get("/v3/job/result/#{e job_id}", {'format'=>format}) {|res|
        if res.code != "200"
          raise_error("Get job result failed", res)
        end

        if ce = res.header['Content-Encoding']
          require 'zlib'
          res.extend(DeflateReadBodyMixin)
          res.gzip = true if ce == 'gzip'
        else
          res.extend(DirectReadBodyMixin)
        end

        res.extend(DirectReadBodyMixin)
        if ce = res.header['Content-Encoding']
          if ce == 'gzip'
            infl = Zlib::Inflate.new(Zlib::MAX_WBITS + 16)
          else
            infl = Zlib::Inflate.new
          end
        end

        total_compr_size = 0
        res.each_fragment {|fragment|
          total_compr_size += fragment.size
          # uncompressed if the 'Content-Enconding' header is set in response
          fragment = infl.inflate(fragment) if ce
          io.write(fragment)
          block.call(total_compr_size) if block_given?
        }
      }
      nil
    else
      code, body, res = get("/v3/job/result/#{e job_id}", {'format'=>format})
      if res.code != "200"
        raise_error("Get job result failed", res)
      end
      body
    end
  end

  # block is optional and must accept 1 argument
  def job_result_each(job_id, &block)
    require 'msgpack'
    get("/v3/job/result/#{e job_id}", {'format'=>'msgpack'}) {|res|
      if res.code != "200"
        raise_error("Get job result failed", res)
      end

      # default to decompressing the response since format is fixed to 'msgpack'
      res.extend(DeflateReadBodyMixin)
      res.gzip = (res.header['Content-Encoding'] == 'gzip')
      upkr = MessagePack::Unpacker.new
      res.each_fragment {|inflated_fragment|
        upkr.feed_each(inflated_fragment, &block)
      }
    }
    nil
  end

  # block is optional and must accept 1 argument
  def job_result_each_with_compr_size(job_id, &block)
    require 'zlib'
    require 'msgpack'

    get("/v3/job/result/#{e job_id}", {'format'=>'msgpack'}) {|res|
      if res.code != "200"
        raise_error("Get job result failed", res)
      end

      res.extend(DirectReadBodyMixin)
      if res.header['Content-Encoding'] == 'gzip'
        infl = Zlib::Inflate.new(Zlib::MAX_WBITS + 16)
      else
        infl = Zlib::Inflate.new
      end
      upkr = MessagePack::Unpacker.new
      begin
        total_compr_size = 0
        res.each_fragment {|fragment|
          total_compr_size += fragment.size
          upkr.feed_each(infl.inflate(fragment)) {|unpacked|
            block.call(unpacked, total_compr_size) if block_given?
          }
        }
      ensure
        infl.close
      end
    }
    nil
  end

  def job_result_raw(job_id, format)
    code, body, res = get("/v3/job/result/#{e job_id}", {'format'=>format})
    if code != "200"
      raise_error("Get job result failed", res)
    end
    return body
  end

  def kill(job_id)
    code, body, res = post("/v3/job/kill/#{e job_id}")
    if code != "200"
      raise_error("Kill job failed", res)
    end
    js = checked_json(body, %w[])
    former_status = js['former_status']
    return former_status
  end

  # => jobId:String
  def hive_query(q, db=nil, result_url=nil, priority=nil, retry_limit=nil, opts={})
    query(q, :hive, db, result_url, priority, retry_limit, opts)
  end

  # => jobId:String
  def pig_query(q, db=nil, result_url=nil, priority=nil, retry_limit=nil, opts={})
    query(q, :pig, db, result_url, priority, retry_limit, opts)
  end

  # => jobId:String
  def query(q, type=:hive, db=nil, result_url=nil, priority=nil, retry_limit=nil, opts={})
    params = {'query' => q}.merge(opts)
    params['result'] = result_url if result_url
    params['priority'] = priority if priority
    params['retry_limit'] = retry_limit if retry_limit
    code, body, res = post("/v3/job/issue/#{type}/#{e db}", params)
    if code != "200"
      raise_error("Query failed", res)
    end
    js = checked_json(body, %w[job_id])
    return js['job_id'].to_s
  end

end
end
