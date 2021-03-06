require 'open-uri'
require 'nokogiri'
require 'digest/sha2'

module Jirest

  API_DOC_URI = 'https://developer.atlassian.com/cloud/jira/platform/rest/v3'

  # A class which stands REST API information
  class ApiInfo

    attr_reader :name, :http_method, :path, :description, :params, :command, :digest

    def initialize(name, http_method, path, description, params, command, digest)
      @name = name
      @http_method = http_method
      @path = path
      @description = description
      @params = params
      @command = command
      @digest = digest
    end

  end

  # A class which store all the REST API information
  class ApiInfoTable

    def initialize
      @hash = {}
    end

    def set(name, api_info)
      @hash[name] = api_info
    end

    def get(name)
      return @hash[name]
    end

    def size
      return @hash.size
    end

    def keys
      return @hash.keys
    end

    def each
      if block_given?
        @hash.each do |key, value|
          yield(key, value)
        end
      end
    end

    # load API definition
    def load_apis
      json = '{}'
      begin
        json = File.read(Jirest::data_dir + '/api.json')
      rescue => e
        Util::error('failed to load API definition!')
      end
      deserialize(json)
    end

    # dump API definition
    def dump_apis
      json = serialize
      begin
        File.write(Jirest::data_dir + '/api.json', json)
      rescue => e
        Util::error 'failed to store API definition!'
      end
    end

    # convert Ruby object information to json
    private def serialize
      obj = {}
      @hash.each do |key, value|
        api = {}
        api['name'] = value.name
        api['http_method'] = value.http_method
        api['path'] = value.path
        api['description'] = value.description
        api['params'] = value.params
        api['command'] = value.command
        api['digest'] = value.digest
        obj[key] = api
      end
      return JSON.generate(obj)
    end

    # convert json to Ruby object
    private def deserialize(json)
      JSON.parse(json).each do |key, value|
        @hash[key] =
            ApiInfo.new(value['name'], value['http_method'], value['path'], value['description'],
                        value['params'], value['command'], value['digest'])
      end
    end

  end

  # A class which is for updating REST API information
  class ApiInfoUpdater

    def initialize(current_api_table)
      @current_api_table = current_api_table
      @latest_api_table = get_latest_api_table
    end

    # replace API params with template variables
    private def normalize_command(command, http_method, params)
      if http_method == 'GET' or http_method == 'DELETE'
        http_params_matcher = /--url '\/.+\?(.*)'/
        md = command.match(http_params_matcher)
        http_params_hash = {}

        return command if md.nil? or md.size < 2
        http_params = md[1].split('&') # HTTP params
        http_params.each do |http_param|
          http_param_pair = http_param.split('=')
          http_params_hash[http_param_pair[0]] = http_param_pair[1]
        end

        params.each do |param|
          name = param['name']

          # check if the parameter is used in the command template
          next if command.include?("{#{name}}")

          # replace param value with template variable
          http_params_hash[name] = "{#{name}}" if !http_params_hash[name].nil?
        end

        # concat all the HTTP request params
        http_params_str = ''
        http_params_hash.each do |key, value|
          http_params_str += "#{key}=#{value}&"
        end
        http_params_str.chop! if http_params_str[-1] == '&' # remove the last '&' character

        # update HTTP request params in the command template
        url_matcher = /--url '(\/.+)\?.*'/
        replacement = '--url \'\1' + '?' + http_params_str + '\''
        command.gsub!(url_matcher, replacement)
      else
        http_params_matcher = /--data '({[\s\S]+})'/
        md = command.match(http_params_matcher)

        return command if md.nil? or md.size < 2

        http_body = md[1]  # HTTP request body
        http_body_hash = JSON.parse(http_body)

        params.each do |param|
          name = param['name']

          # check if the parameter is used in the command template
          next if command.include?("{#{name}}")

          # next if the command template has HTTP request body
          next if http_body_hash.nil?

          # replace param value with template variable
          http_body_hash[name] = "{#{name}}" if !http_body_hash[name].nil?
        end

        # update HTTP request body in the command template if any change
        if !http_body_hash.nil?
          http_body = JSON.pretty_generate(http_body_hash)
          command.gsub!(http_params_matcher, "--data '#{http_body}'")
        end
      end

      return command
    end

    # calculate digest of each API information
    private def calc_digest(name, description, params, command)
      str = name
      str += description
      params.each do |param|
        str += param['name'] # param name
      end
      str += command
      return Digest::SHA256.hexdigest(str)
    end

    # retrieve the latest API information
    private def get_latest_api_table
      latest_api_table = ApiInfoTable.new

      charset = nil
      html = open(API_DOC_URI) do |f|
        charset = f.charset
        f.read
      end

      doc = Nokogiri::HTML.parse(html, nil, charset)
      doc.css('h3').each do |h3|
        # check if the 'h3' tag is about REST API information
        if not h3.attribute('id').value.start_with?('api-rest-api')
          next
        end

        name = h3.content
        root_api_elem = h3.parent

        # extract API method and path
        method_path_pair = root_api_elem.css('p').first.content.split(' ')
        http_method = method_path_pair[0]
        path = method_path_pair[1]

        # extract API description
        description = h3.next.next.content

        # extract parameters
        params = []
        h5_arr = root_api_elem.css('h5')
        if not h5_arr.empty? and h5_arr.first.content.end_with?('parameters')
          section_arr = h5_arr.first.parent.css('section')
          unless section_arr.empty?
            section_arr.each do |section|
              param_info = {}
              strong_arr = section.css('strong')
              param_info['name'] = strong_arr[0].content.chomp(' ') unless strong_arr.empty?
              span_arr = section.css('p > span')
              param_info['type'] = span_arr[0].content.chomp(' ') unless span_arr.empty?
              p_arr = section.css('div > p')
              param_info['description'] = p_arr[0].content.chomp(' ') unless p_arr.empty?
              code_arr = section.css('div > span > span > span > code')
              param_info['default'] = code_arr[0].content.chomp(' ') unless code_arr.empty?
              params.push(param_info)
            end
          end
        end

        # extract 'curl' command
        command = nil
        root_api_elem.css('h4').each do |h4|
          if h4.content == 'Example'
            div = h4.next
            code_arr = div.css('code')
            if not code_arr.empty?
              command = code_arr.last.content
            end
          end
        end
        next if command.nil?

        normalized_command = normalize_command(command, http_method, params)
        digest = calc_digest(name, description, params, command)
        latest_api_table.set(name, ApiInfo.new(name, http_method, path, description, params, normalized_command, digest))
      end

      return latest_api_table
    end

    # check if any API is changed on the API reference
    private def is_api_changed
      # true if number of APIs is changed
      ret = @current_api_table.size != @latest_api_table.size

      # true if digest of each API is changed
      @current_api_table.each do |key, value|
        latest_api = @latest_api_table.get(key)
        if latest_api.nil? || (latest_api.digest != value.digest)
          ret = true
          Util::msg "'#{key}' API was updated."
        end
      end
      return ret
    end

    # update API information
    def update
      Util::msg 'API information updating...'
      if is_api_changed
        @latest_api_table.dump_apis
      else
        Util::msg 'API Info is up to date.'
      end
    end

  end

end