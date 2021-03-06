# frozen_string_literal: true

class AssemblaService < Service
  prop_accessor :token, :subdomain
  validates :token, presence: true, if: :activated?

  def title
    'Assembla'
  end

  def description
    '项目管理软件 (代码提交终端)'
  end

  def self.to_param
    'assembla'
  end

  def fields
    [
      { type: 'text', name: 'token', placeholder: '', required: true },
      { type: 'text', name: 'subdomain', placeholder: '' }
    ]
  end

  def self.supported_events
    %w(push)
  end

  def execute(data)
    return unless supported_events.include?(data[:object_kind])

    url = "https://atlas.assembla.com/spaces/#{subdomain}/github_tool?secret_key=#{token}"
    Gitlab::HTTP.post(url, body: { payload: data }.to_json, headers: { 'Content-Type' => 'application/json' })
  end
end
