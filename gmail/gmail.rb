require 'rubygems'
require 'google/api_client'
require 'google/api_client/client_secrets'
require 'google/api_client/auth/file_storage'
require 'google/api_client/auth/installed_app'
require 'sinatra'
require 'logger'
require 'base64'
require 'mail'
require 'tempfile'

enable :sessions

def logger; settings.logger end

def api_client; settings.api_client; end

def gmail_api; settings.gmail; end

configure do
  log_file = File.open('gmail.log', 'a+')
  log_file.sync = true
  logger = Logger.new(log_file)
  logger.level = Logger::DEBUG

  client = Google::APIClient.new(
    :application_name => 'Ruby Gmail sample',
    :application_version => '1.0.0')

  gmail = client.discovered_api('gmail', 'v1')

  set :logger, logger
  set :api_client, client
  set :gmail, gmail
end

before do
  # Ensure user has authorized the app
  # redirect user_credentials.authorization_uri.to_s, 303
  # FileStorage stores auth credentials in a file, so they survive multiple runs
  # of the application. This avoids prompting the user for authorization every
  # time the access token expires, by remembering the refresh token.
  # Note: FileStorage is not suitable for multi-user applications.
  unless session[:secret]
    secret_file = %(#{Time.now}.json)
    session[:secret] = secret_file
    TempFile.new(secret_file)
  end
  file_storage = Google::APIClient::FileStorage.new(session[:secret])
  if file_storage.authorization.nil?
    client_secrets = Google::APIClient::ClientSecrets.load
    # The InstalledAppFlow is a helper class to handle the OAuth 2.0 installed
    # application flow, which ties in with FileStorage to store credentials
    # between runs.
    flow = Google::APIClient::InstalledAppFlow.new(
      :client_id => client_secrets.client_id,
      :client_secret => client_secrets.client_secret,
      :scope => ['https://www.googleapis.com/auth/gmail.compose']
    )
    api_client.authorization = flow.authorize(file_storage)
  else
    api_client.authorization = file_storage.authorization
  end
end

get '/list/:email' do
  # Fetch list of emails on the user's gmail
  if params[:email]
    @result = api_client.execute(
      api_method: gmail_api.users.messages.list,
      parameters: {
          userId: params[:email],
          q: 'from:fairwater@australand.com.au'
      },
      headers: {'Content-Type' => 'application/json'}).data
    @latest = @result.messages.first.id
    if session[:latest_id]
      session[:latest_id] = @latest if session[:latest_id] != @latest
      @message = "New email detected"
    else
      session[:latest_id] = @latest
      @message = "No new email"
    end
    erb :index
  else
    'Email is required'
  end
end

get '/' do
  'Email is required'
end

get '/latest/:email' do
  if session[:latest_id]
    @result = api_client.execute(
      api_method: gmail_api.users.messages.get,
      parameters: {
          userId: params[:email],
          id: session[:latest_id]
      },
      headers: {'Content-Type' => 'application/json'})
    erb :latest
  else
    'Please fetch latest email from "/" first'
  end
end

get '/send/:email' do
  @msg = Mail.new
  @msg.date = Time.now
  @msg.subject = "Secure your new home today - The Greenbank Collection at Fairwater."
  @msg.body = "I would like to secure an appointment to purchase a new Greenbank Collection\r\nhome at Fairwater:\r\n FIRST NAME : Lecky\r\n LAST NAME : Lao\r\n CONTACT PHONE NUMBER : 0455 069 492\r\n"
  @msg.from = params[:email]
  @msg.to = "leckylao@gmail.com"
  @msg.html_part do
    body "<div dir=\"ltr\">I would like to secure an appointment to purchase a new Greenbank Collection home at Fairwater:<br> FIRST NAME : Lecky<br> LAST NAME : Lao<br> CONTACT PHONE NUMBER : 0455 069 492<br></div>\r\n"
  end
  @result = api_client.execute(
    api_method: gmail_api.users.messages.to_h['gmail.users.messages.send'],
    parameters: {
      userId: params[:email],
    },
    body_object: {
      raw: Base64.urlsafe_encode64(@msg.to_s)
    },
    headers: {'Content-Type' => 'application/json'})
  erb :send
end

get '/test/:email' do
  fetch_and_send(params[:email])
  erb :send
end

get '/real/:email' do
  fetch_and_send(params[:email])
  erb :send
end

def text_message(email)
  if email == 'leckylao@gmail.com'
    "I would like to secure an appointment to purchase a new Greenbank Collection\r\nhome at Fairwater:\r\n FIRST NAME : Lecky\r\n LAST NAME : Lao\r\n CONTACT PHONE NUMBER : 0455 069 492\r\n"
  else
    "Email is required"
  end
end

def html_message(email)
  if email == 'leckylao@gmail.com'
    "<div dir=\"ltr\">I would like to secure an appointment to purchase a new Greenbank Collection home at Fairwater:<br> FIRST NAME : Lecky<br> LAST NAME : Lao<br> CONTACT PHONE NUMBER : 0455 069 492<br></div>"
  else
    "<div dir=\"ltr\">Email is required</div>"
  end
end

def fetch_and_send(email)
  # Fetch list of emails on the user's gmail
  query = ''
  if request.path_info =~ /\A\/test\/.*\z/
    query = 'subject:test'
  elsif request.path_info =~ /\A\/real\/.*\z/
    query = 'from:fairwater@australand.com.au'
  end
  logger.info "Query: #{query}"
  logger.info "Email: #{email}"
  @result = api_client.execute(
    api_method: gmail_api.users.messages.list,
    parameters: {
      userId: email,
      q: query
    },
    headers: {'Content-Type' => 'application/json'}).data
  logger.info "Result: #{@result.inspect}"
  if @result.messages.empty?
    return @message = @result.inspect
  else
    @latest = @result.messages.first.id
  end
  if session[:latest_id]
    if session[:latest_id] != @latest
      session[:latest_id] = @latest
      @msg = Mail.new
      @msg.date = Time.now
      @msg.subject = "Secure your new home today - The Greenbank Collection at Fairwater."
      @msg.body = text_message(email)
      @msg.from = email
      @msg.to = email
      @msg.html_part do
        body html_message(email)
      end
      @result = api_client.execute(
        api_method: gmail_api.users.messages.to_h['gmail.users.messages.send'],
        parameters: {
          userId: email,
        },
        body_object: {
          raw: Base64.urlsafe_encode64(@msg.to_s)
        },
        headers: {'Content-Type' => 'application/json'})
      @message = "Email sent successfully"
    else
      @message = "No new email"
    end
  else
    session[:latest_id] = @latest
    @message = "Latest email stored"
  end
end
