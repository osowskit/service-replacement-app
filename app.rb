require "sinatra"
require "sinatra/json"
require "octokit"
require "active_support/core_ext/numeric/time"
require 'dotenv'
require "jwt"
require 'yaml'

Dotenv.load
$stdout.sync = true

CLIENT_ID = ENV.fetch("GITHUB_CLIENT_ID")
CLIENT_SECRET = ENV["GITHUB_CLIENT_SECRET"]
GITHUB_API_ENDPOINT = "https://api.github.com/"
GITHUB_KEY_LOCATION = ENV.fetch("GITHUB_KEY_LOCATION", nil)
if GITHUB_KEY_LOCATION.nil?
  GITHUB_APP_KEY = ENV.fetch("GITHUB_APP_KEY")
else
  info = File.read(GITHUB_KEY_LOCATION)
  GITHUB_APP_KEY = info
end
GITHUB_APP_ID = ENV.fetch("GITHUB_APP_ID")
GITHUB_APP_URL = ENV.fetch("GITHUB_APP_URL")
SESSION_SECRET = ENV.fetch("SESSION_SECRET")

# Load service replacement
yml = File.open('service-replacement.yaml')
$service_replacement_list = YAML.load(yml)

enable :sessions
set :session_secret, SESSION_SECRET

Octokit.configure do |c|
  c.default_media_type = "application/vnd.github.machine-man-preview+json"
  c.auto_paginate = true
  c.user_agent = "#{Octokit.user_agent}: service-deprecation-app"
end

# Ask the user to authorise the app.
def authenticate!
  @client = Octokit::Client.new
  url = @client.authorize_url(CLIENT_ID)
  redirect url
end

def install!
  redirect GITHUB_APP_URL
end

# Check whether the user has an access token.
def authenticated?
  session[:access_token]
end

def installed?
  !session[:installation_list].nil? && session[:installation_list].count > 0
end

def check_installations
  @access_token = session[:access_token]
  installation_ids = []
  begin
    @client = Octokit::Client.new :access_token => @access_token
    response = @client.find_user_installations

    installation_count = response.total_count
    if installation_count > 0
      response.installations.each do |installation|
        installation_ids.push(installation.id)
      end
    end
    session[:installation_list] = installation_ids
  rescue => e
    session[:installation_list] = nil
    authenticate!
  end
end

def get_jwt
  private_pem = GITHUB_APP_KEY
  private_key = OpenSSL::PKey::RSA.new(private_pem)

  payload = {
    # issued at time
    iat: Time.now.to_i,
    # JWT expiration time (10 minute maximum)
    exp: 5.minutes.from_now.to_i,
    # Integration's GitHub identifier
    iss: GITHUB_APP_ID
  }

  JWT.encode(payload, private_key, "RS256")
end

def get_app_token(installation_id)
  return_token = ''
  begin
    @jwt_client = Octokit::Client.new(:bearer_token => get_jwt, :accept => @accept_header)
    new_token = @jwt_client.create_app_installation_access_token(installation_id, :accept => @accept_header)
    return_token = new_token.token
  rescue => error
    puts error
  end

  return return_token
end

# Check whether the user's access token is valid.
def check_access_token
  @access_token = session[:access_token]

  begin
    @client = Octokit::Client.new :access_token => @access_token
    @user = @client.find_user_installations
  rescue => e
    # The token has been revoked, so invalidate the token in the session.
    session[:access_token] = nil
    authenticate!
  end
end

def select_installation!(installation_id)
  session[:selected_installation] = installation_id
end

def installation_selected?
  session[:selected_installation]
end

get "/reset" do
  session[:selected_installation] = nil
  session[:installation_list] = nil
  session[:access_token] = nil
  redirect "/"
end

def installations
  @client = Octokit::Client.new(:access_token => session[:access_token])
  @client.find_user_installations[:installations]
end


# Wrapper route for redirecting the user to authorise the app.
get "/auth" do
  authenticate!
end

get "/install" do
  install!
end

# Serve the main page.
get "/" do
  if !authenticated?
    return erb :how, :locals => { :authenticated => authenticated? }
  end
  check_access_token
  check_installations
  if !installed?
    return erb :install, :locals => { :authenticated => authenticated?, :installed => installed?}
  else
    erb :index, :locals => {
      :authenticated => authenticated?,  :installations => installations, :installation_selected => installation_selected?}
  end
end

def replace_hook(installation_id, repository_name, hook_id)

  app_token = get_app_token(installation_id)
  return 404 unless app_token != ''
  @app_client = Octokit::Client.new(:access_token => app_token)

  # Get old hooks 
  result = @app_client.hook(repository_name, hook_id, :accept => "application/vnd.github.machine-man-preview+json")
  params = ""
  events = ['push']
  if result.name == "jenkinsgit"
    url = result.config.jenkins_url
    # TODO: Look up repository URL to support GitHub Enterprise
    params = "/git/notifyCommit?url=http://github.com/#{repository_name}"
    hook_data = {:jenkins_url => jenkins_url}
  elsif result.name == "jenkins"
    url = result.config.jenkins_hook_url
    hook_data = {:jenkins_hook_url => jenkins_url}
  elsif result.name == "docker"
    url = "https://registry.hub.docker.com/hooks/github"
    hook_data = {}
  elsif result.name == "codereviewhub"
    url = "https://www.codereviewhub.com"
    hook_data = {}
    events = ['push', "pull_request", "issue_comment", "commit_comment", "pull_request_review_comment"]
  else
    puts "unknown error"
    return nil
  end

  # Add repo webhook for `push` events
  begin
    create_result = @app_client.create_hook(repository_name, 'web',
      {
        :url => "#{url}#{params}",
        :content_type => 'json'
      },
      {
        :events => events,
        :active => true
      }
    )
  rescue => e
    puts e
    return 400
  end

  # Disable old Service Hook if webhook creation succeeded
  begin
    result = @app_client.edit_hook(repository_name, hook_id, 'jenkinsgit', hook_data, {
      :active => false
    })
  rescue => e
    puts e
    return 400
  end
  return 201
end

# Return a all the Service hooks installed on a Repository
def get_hook_list(installation_id, repository_name, local_client)
  hook_list = Array.new

  begin
    results = local_client.hooks(repository_name, :accept => "application/vnd.github.machine-man-preview+json")

    # Search for all service hooks on a repository
    results.each do |hook|
      if hook.name == 'jenkinsgit' && hook.active 
        replacement = $service_replacement_list[hook.name]
        hook_list.push({id: hook.id, hook_name: hook.name, replacement: "#{replacement['url']}?repo_name=#{repository_name}&hook_id=#{hook.id}&installation_id=#{installation_id}", message: replacement['message']})
      elsif hook.name == 'jenkins' && hook.active        
        replacement = $service_replacement_list[hook.name]
        hook_list.push({id: hook.id, hook_name: hook.name, replacement: "#{replacement['url']}?repo_name=#{repository_name}&hook_id=#{hook.id}&installation_id=#{installation_id}", message: replacement['message']})
      elsif hook.name == 'docker' && hook.active
        replacement = $service_replacement_list[hook.name]
        hook_list.push({id: hook.id, hook_name: hook.name, replacement: "#{replacement['url']}?repo_name=#{repository_name}&hook_id=#{hook.id}&installation_id=#{installation_id}", message: replacement['message']})
      elsif hook.name != 'web'
        puts hook.name
      end
    end
  rescue => err
    puts err
  end

  hook_list
end

# Respond to requests to check a commit. The commit URL is included in the
# url param.
post "/" do
  authenticate! if !authenticated?
  check_access_token

  install if !installed?

  # Select an Installation
  installation_id = params[:installation_id].to_i
  begin
    result = {repo_list: []}

    @client.auto_paginate = true
    response = @client.find_installation_repositories_for_user(installation_id)
    app_token = get_app_token(installation_id)
    return 404 unless app_token != ''
    @app_client = Octokit::Client.new(:access_token => app_token)
    @app_client.auto_paginate = true

    if response.total_count > 0
      response.repositories.each do |repo|
        hook_list = get_hook_list(params[:installation_id], repo["full_name"], @app_client)

        if !hook_list.nil? && hook_list.count > 0
          return_data = {full_name: repo["full_name"], installation_id: installation_id, hooks: hook_list}
          result[:repo_list].push(return_data)
        end
      end
    end

    result[:commit_url] = params[:installation_id]
  rescue => err
    return json :error_message => err
  end
  json result
end

get "/replace_jenkins" do
  installation_id = params[:installation_id]
  repo_name = params[:repo_name]
  hook_id = params[:hook_id]
  replace_hook(installation_id, repo_name, hook_id)
end

# Remove and generalize
get "/replace_codereviewhub" do
  installation_id = params[:installation_id]
  repo_name = params[:repo_name]
  hook_id = params[:hook_id]
  replace_hook(installation_id, repo_name, hook_id)

  # Success
  redirect "/"  
end

get "/replace_docker" do
  installation_id = params[:installation_id]
  repo_name = params[:repo_name]
  hook_id = params[:hook_id]
  replace_hook(installation_id, repo_name, hook_id)
  
  # Success
  redirect "/"
end

# Handle the redirect from GitHub after someone authorises the app.
get "/callback" do
  session_code = params[:code]
  result = Octokit.exchange_code_for_token \
    session_code, CLIENT_ID, CLIENT_SECRET, :accept => "application/json"
  session[:access_token] = result.access_token
  redirect "/"
end

# Show the 'How does this work?' page.
get "/how" do
  erb :how, :locals => { :authenticated => authenticated? }
end

get "/debug-x" do 
  puts session[:access_token]
end

get "/debug" do
  access_token = params[:token]
  session[:access_token] = access_token
end

# Ping endpoing for uptime check.
get "/ping" do
  "pong"
end
