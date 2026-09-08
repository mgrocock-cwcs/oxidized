require 'digest/md5'
require 'json'
require 'zip'

class FTD < Oxidized::Model
  cfg_cb = lambda do
    payload = {
      'grant_type' => 'password',
      'username'   => @node.auth[:username],
      'password'   => @node.auth[:password]
    }.to_json

    begin
      token = JSON.parse(post_http("#{@api_endpoint}/fdm/token", payload))
    rescue StandardError
      raise Oxidized::OxidizedError, 'login failed'
    end

    @headers['Authorization'] = "#{token['token_type']} #{token['access_token']}"

    # Delete any pre-existing config export, otherwise the configexport method will fail.
    delete_http("#{@api_endpoint}/action/configfiles/#{@config_filename}")

    payload = {
      'type'                => 'scheduleconfigexport',
      'diskFileName'        => @config_filename,
      'doNotEncrypt'        => true,
      'deployedObjectsOnly' => true
    }.to_json

    obj_id = JSON.parse(post_http("#{@api_endpoint}/action/configexport", payload))['jobHistoryUuid']
    job_status = nil

    @retries.times do
      job_status = JSON.parse(get_http("#{@api_endpoint}/jobs/configexportstatus/#{obj_id}"))
      break if %w[SUCCESS FAILED].include?(job_status['status'])

      sleep(@retry_secs)
    end

    if job_status['status'] != 'SUCCESS'
      if job_status['status'] == 'FAILED'
        raise Oxidized::OxidizedError, job_status['statusMessage']
      elsif job_status['error']
        raise Oxidized::OxidizedError, job_status['error']['messages'][0]['description']
      else
        raise Oxidized::OxidizedError, 'unknown error'
      end
    end

    config = JSON.parse(Zip::File.open_buffer(get_http("#{@api_endpoint}/action/downloadconfigfile/#{@config_filename}")).read('full_config.txt'))

    delete_http("#{@api_endpoint}/action/configfiles/#{@config_filename}")

    # generatedOn contains the timestamp of the config export. Delete it to avoid unnecessary differences.
    config[0].delete('generatedOn')

    # The distiniguishedNames list seems to change order between exports. Sort it deterministically to avoid unnecessary differences.
    index = config.find_index { |element| element['type'] == 'identitywrapper' and element['data']['type'] == 'distinguishednamegroup' }

    if index
      config[index]['data']['distiniguishedNames'].sort_by! { |element| Digest::MD5.hexdigest(element['id']).to_i(16) }
    end

    JSON.pretty_generate(config)
  end

  cmd cfg_cb

  cfg :http do
    @api_endpoint = vars(:ftd_api_endpoint) || '/api/fdm/latest'
    @config_filename = vars(:ftd_config_filename) || 'oxidized.zip'
    @retries = vars(:ftd_retries) || 10
    @retry_secs = vars(:ftd_retry_secs) || 6

    @secure = true
    @port = vars(:ftd_api_port) || 443

    @headers = {
      'Accept'       => 'application/json',
      'Content-Type' => 'application/json'
    }
  end
end
