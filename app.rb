require 'sinatra'
require 'sinatra/reloader' if development?
require 'json'
require 'fileutils'
require 'zip'
require 'rufus-scheduler'
require 'securerandom'
require 'open3'

set :bind, '127.0.0.1'
set :port, ENV.fetch('PORT', '4567').to_i
set :public_folder, File.expand_path('public', __dir__)
set :views, File.expand_path('views', __dir__)
set :sessions, secret: ENV.fetch('SESSION_SECRET') { SecureRandom.hex(32) }

DATA_DIR = File.expand_path('data', __dir__)
CONFIG_FILE = File.join(DATA_DIR, 'config.json')
BACKUPS_FILE = File.join(DATA_DIR, 'backups.json')
LOGS_FILE = File.join(DATA_DIR, 'logs.json')
CACHE_DIR = File.join(DATA_DIR, 'cache')
UPLOADS_DIR = File.join(DATA_DIR, 'uploads')
CACHE_FILES_FILE = File.join(DATA_DIR, 'cache_files.json')
CLOUD_FILES_FILE = File.join(DATA_DIR, 'cloud_files.json')
FileUtils.mkdir_p(DATA_DIR)
FileUtils.mkdir_p(CACHE_DIR)
FileUtils.mkdir_p(UPLOADS_DIR)

CONFIG_MUTEX = Mutex.new

def read_json(path, default)
  return default unless File.exist?(path)

  JSON.parse(File.read(path))
rescue JSON::ParserError
  default
end

def write_json(path, value)
  tmp = "#{path}.tmp"
  File.write(tmp, JSON.pretty_generate(value))
  File.rename(tmp, path)
end

def load_config
  read_json(CONFIG_FILE, { 'tasks' => [], 'automatic_enabled' => true })
end

def save_config(config)
  write_json(CONFIG_FILE, config)
end

def load_backups
  read_json(BACKUPS_FILE, [])
end

def save_backups(backups)
  write_json(BACKUPS_FILE, backups)
end

def load_logs
  read_json(LOGS_FILE, [])
end

def load_cloud_files
  read_json(CLOUD_FILES_FILE, [])
end

def save_cloud_files(files)
  write_json(CLOUD_FILES_FILE, files)
end

def load_cache_files
  read_json(CACHE_FILES_FILE, [])
end

def save_cache_files(files)
  write_json(CACHE_FILES_FILE, files)
end

def add_log(status, message)
  CONFIG_MUTEX.synchronize do
    logs = load_logs
    logs.unshift({ 'timestamp' => Time.now.iso8601, 'status' => status, 'message' => message })
    logs = logs.first(100)
    save_json_safe(LOGS_FILE, logs)
  end
end

def save_json_safe(path, value)
  write_json(path, value)
rescue SystemCallError => e
  warn "Could not write #{path}: #{e.message}"
end

def expanded_path(path)
  File.expand_path(path.to_s.strip)
end

def safe_backup_destination(destination)
  path = expanded_path(destination)
  raise ArgumentError, 'Destination folder is required' if path.empty?

  FileUtils.mkdir_p(path)
  raise ArgumentError, 'Destination folder is not writable' unless File.writable?(path)

  path
end

def add_directory_to_zip(zip, source_path)
  root_name = File.basename(source_path)
  if File.directory?(source_path)
    Dir.chdir(File.dirname(source_path)) do
      Dir.glob(File.join(root_name, '**', '*'), File::FNM_DOTMATCH).each do |relative|
        next if relative.end_with?('/.') || relative.end_with?('/..')
        next if File.symlink?(relative)

        if File.directory?(relative)
          zip.mkdir(relative)
        elsif File.file?(relative)
          zip.add(relative, relative)
        end
      end
    end
  end
end

def run_backup(task)
  source = expanded_path(task['source'])
  raise ArgumentError, 'Source path is not configured' if task['source'].to_s.strip.empty?
  raise Errno::ENOENT, "Source path does not exist: #{source}" unless File.exist?(source)

  destination = safe_backup_destination(task['destination'])
  stamp = Time.now.strftime('%Y%m%d-%H%M%S')
  name = "#{Sanitize.basename(task['name'].to_s.empty? ? 'backup' : task['name'])}-#{stamp}-#{SecureRandom.hex(3)}.zip"
  zip_path = File.join(destination, name)

  Zip::File.open(zip_path, create: true) do |zip|
    if File.directory?(source)
      add_directory_to_zip(zip, source)
    else
      zip.add(File.basename(source), source)
    end
  end

  record = {
    'id' => SecureRandom.uuid,
    'name' => name,
    'path' => zip_path,
    'source' => source,
    'source_type' => File.directory?(source) ? 'directory' : 'file',
    'task_id' => task['id'],
    'created_at' => Time.now.iso8601,
    'size' => File.size(zip_path)
  }
  CONFIG_MUTEX.synchronize do
    backups = load_backups
    backups.unshift(record)
    save_backups(backups)
  end
  add_log('success', "Backup created: #{name}")
  record
rescue Zip::Error, SystemCallError, ArgumentError => e
  add_log('error', "Backup failed for #{task['name']}: #{e.message}")
  nil
end

module Sanitize
  def self.basename(value)
    value.to_s.gsub(/[^a-zA-Z0-9._-]/, '_').delete_prefix('.').slice(0, 60)
  end
end

SCHEDULER = Rufus::Scheduler.singleton
SCHEDULE_JOBS = {}

class << self
  def schedule_all
    SCHEDULE_JOBS.each_value(&:unschedule)
    SCHEDULE_JOBS.clear
    config = load_config
    return unless config['automatic_enabled']

    config['tasks'].each do |task|
      next unless task['enabled'] != false

      interval = task['interval'].to_i
      next if interval <= 0

      duration = "#{interval}#{task['unit'] == 'hours' ? 'h' : 'm'}"
      SCHEDULE_JOBS[task['id']] = SCHEDULER.every(duration) do
        current = load_config['tasks'].find { |item| item['id'] == task['id'] }
        run_backup(current) if current && current['enabled'] != false && load_config['automatic_enabled'
        ]
      end
    end
  end
end

schedule_all

helpers do
  def h(value)
    Rack::Utils.escape_html(value.to_s)
  end

  def format_bytes(bytes)
    value = bytes.to_f
    %w[B KB MB GB TB].each do |unit|
      return "#{format('%0.1f', value)} #{unit}" if value < 1024.0
      value /= 1024.0
    end
  end

  def format_time(value)
    Time.iso8601(value).strftime('%Y-%m-%d %H:%M:%S')
  rescue ArgumentError
    value
  end
end

get '/' do
  sync_cloud_files
  @config = load_config
  @backups = load_backups
  @cloud_files = load_cloud_files
  @cache_files = load_cache_files
  @logs = load_logs
  erb :index
end

post '/tasks' do
  config = load_config
  source = expanded_path(params[:source])
  destination = expanded_path(params[:destination])
  interval = params[:interval].to_i

  if source.empty? || destination.empty? || interval <= 0
    session[:flash] = { 'status' => 'error', 'message' => 'Name, source, destination, and a positive interval are required.' }
  elsif !File.exist?(source)
    session[:flash] = { 'status' => 'error', 'message' => "Source path does not exist: #{source}" }
  else
    begin
      FileUtils.mkdir_p(destination)
      task = {
        'id' => SecureRandom.uuid,
        'name' => params[:name].to_s.strip,
        'source' => source,
        'destination' => destination,
        'interval' => interval,
        'unit' => params[:unit] == 'hours' ? 'hours' : 'minutes',
        'enabled' => true
      }
      config['tasks'] << task
      save_config(config)
      schedule_all
      add_log('success', "Task added: #{task['name']}")
      session[:flash] = { 'status' => 'success', 'message' => 'Backup task added.' }
    rescue SystemCallError => e
      session[:flash] = { 'status' => 'error', 'message' => e.message }
    end
  end
  redirect '/'
end

get '/tasks/:id/edit' do
  @config = load_config
  @task = @config['tasks'].find { |task| task['id'] == params[:id] }
  halt 404, 'Task not found' unless @task
  erb :edit_task
end

post '/tasks/:id/edit' do
  config = load_config
  task = config['tasks'].find { |item| item['id'] == params[:id] }
  halt 404, 'Task not found' unless task

  source = expanded_path(params[:source])
  destination = expanded_path(params[:destination])
  interval = params[:interval].to_i
  if source.empty? || destination.empty? || interval <= 0 || !File.exist?(source)
    session[:flash] = { 'status' => 'error', 'message' => 'Invalid task: source must exist and interval must be positive.' }
  else
    begin
      FileUtils.mkdir_p(destination)
      task.merge!('name' => params[:name].to_s.strip, 'source' => source, 'destination' => destination,
                  'interval' => interval, 'unit' => params[:unit] == 'hours' ? 'hours' : 'minutes')
      save_config(config)
      schedule_all
      add_log('success', "Task updated: #{task['name']}")
      session[:flash] = { 'status' => 'success', 'message' => 'Backup task updated.' }
    rescue SystemCallError => e
      session[:flash] = { 'status' => 'error', 'message' => e.message }
    end
  end
  redirect '/'
end

post '/tasks/:id/toggle' do
  config = load_config
  task = config['tasks'].find { |item| item['id'] == params[:id] }
  halt 404, 'Task not found' unless task
  task['enabled'] = !task['enabled']
  save_config(config)
  schedule_all
  add_log('info', "Task #{task['enabled'] ? 'resumed' : 'paused'}: #{task['name']}")
  session[:flash] = { 'status' => 'success', 'message' => "Task #{task['enabled'] ? 'resumed' : 'paused'}." }
  redirect '/'
end

post '/tasks/:id/run' do
  config = load_config
  task = config['tasks'].find { |item| item['id'] == params[:id] }
  halt 404, 'Task not found' unless task
  record = run_backup(task)
  session[:flash] = record ? { 'status' => 'success', 'message' => 'Backup completed.' } : { 'status' => 'error', 'message' => 'Backup failed. See activity log.' }
  redirect '/'
end

post '/tasks/:id/delete' do
  config = load_config
  task = config['tasks'].find { |item| item['id'] == params[:id] }
  halt 404, 'Task not found' unless task
  config['tasks'].reject! { |item| item['id'] == params[:id] }
  save_config(config)
  schedule_all
  add_log('info', "Task deleted: #{task['name']}")
  session[:flash] = { 'status' => 'success', 'message' => 'Backup task deleted.' }
  redirect '/'
end

post '/automation/pause' do
  config = load_config
  config['automatic_enabled'] = false
  save_config(config)
  schedule_all
  add_log('info', 'Automatic backups paused')
  session[:flash] = { 'status' => 'success', 'message' => 'Automatic backups paused.' }
  redirect '/'
end

post '/automation/resume' do
  config = load_config
  config['automatic_enabled'] = true
  save_config(config)
  schedule_all
  add_log('success', 'Automatic backups resumed')
  session[:flash] = { 'status' => 'success', 'message' => 'Automatic backups resumed.' }
  redirect '/'
end

post '/backups/:id/restore' do
  backup = load_backups.find { |item| item['id'] == params[:id] }
  halt 404, 'Backup not found' unless backup
  halt 404, 'Backup archive is missing' unless File.exist?(backup['path'])

  custom_target = params[:target].to_s.strip
  if custom_target.empty?
    restore_root = backup['source_type'] == 'directory' ? File.dirname(backup['source']) : File.dirname(backup['source'])
  else
    restore_root = expanded_path(custom_target)
  end

  begin
    overwrite = params[:overwrite] == '1'
    restored = 0
    Zip::File.open(backup['path']) do |zip|
      zip.each do |entry|
        next if entry.directory?

        destination = File.expand_path(entry.name, restore_root)
        prefix = File.expand_path(restore_root)
        unless destination.start_with?(prefix + File::SEPARATOR) || destination == prefix
          raise ArgumentError, "Unsafe archive entry: #{entry.name}"
        end

        FileUtils.mkdir_p(File.dirname(destination))
        next if File.exist?(destination) && !overwrite

        entry.extract(destination) { true }
        restored += 1
      end
    end
    add_log('success', "Restore completed: #{backup['name']} (#{restored} files)")
    session[:flash] = { 'status' => 'success', 'message' => "Restore completed to #{restore_root}. #{restored} files restored." }
  rescue Zip::Error, SystemCallError, ArgumentError => e
    add_log('error', "Restore failed for #{backup['name']}: #{e.message}")
    session[:flash] = { 'status' => 'error', 'message' => "Restore failed: #{e.message}" }
  end
  redirect '/'
end

post '/backups/:id/delete' do
  backup = nil
  CONFIG_MUTEX.synchronize do
    backups = load_backups
    backup = backups.find { |item| item['id'] == params[:id] }
    halt 404, 'Backup not found' unless backup
    backups.reject! { |item| item['id'] == params[:id] }
    File.delete(backup['path']) if File.exist?(backup['path'])
    save_backups(backups)
  end
  add_log('info', "Backup deleted: #{backup['name']}")
  session[:flash] = { 'status' => 'success', 'message' => 'Backup archive deleted.' }
  redirect '/'
end

GOOGLE_DRIVE_REMOTE = 'GoogleDrive:'

def sync_cloud_files
  stdout, stderr, status = Open3.capture3('rclone', 'lsjson', GOOGLE_DRIVE_REMOTE, '--recursive')
  unless status.success?
    warn "Google Drive sync failed: #{stderr.strip}"
    add_log('error', "Google Drive sync failed: #{stderr.strip}") unless stderr.to_s.strip.empty?
    return load_cloud_files
  end

  entries = JSON.parse(stdout)
  files = entries.filter_map do |entry|
    next if entry['IsDir']

    {
      'id' => entry['ID'].to_s.empty? ? SecureRandom.uuid : entry['ID'],
      'google_id' => entry['ID'],
      'name' => entry['Name'],
      'remote_path' => entry['Path'],
      'original_path' => entry['Path'],
      'created_at' => entry['ModTime'],
      'size' => entry['Size'].to_i
    }
  end
  save_cloud_files(files)
  files
rescue JSON::ParserError, SystemCallError => e
  warn "Google Drive sync failed: #{e.message}"
  load_cloud_files
end

get '/cloud_files' do
  sync_cloud_files
  @cloud_files = load_cloud_files
  erb :cloud_files
end

post '/cloud_files/delete' do
  file = params[:file]
  cloud_file = load_cloud_files.find { |item| item['id'] == file }
  halt 404, 'File not found' unless cloud_file

  remote_path = "#{GOOGLE_DRIVE_REMOTE}#{cloud_file['remote_path']}"
  success = system('rclone', 'deletefile', remote_path)
  if success
    CONFIG_MUTEX.synchronize do
      save_cloud_files(load_cloud_files.reject { |item| item['id'] == file })
    end
    add_log('info', "Cloud file deleted: #{cloud_file['name']}")
    session[:flash] = { 'status' => 'success', 'message' => 'Cloud file deleted.' }
  else
    add_log('error', "Cloud delete failed for #{cloud_file['name']}")
    session[:flash] = { 'status' => 'error', 'message' => 'Could not delete the cloud file.' }
  end
  redirect '/cloud_files'
end

post '/cloud_files/restore' do
  file = params[:file]
  cloud_file = load_cloud_files.find { |item| item['id'] == file }
  halt 404, 'File not found' unless cloud_file

  target = params[:target].to_s.strip
  halt 400, 'Restore target is required' if target.empty?

  target_path = expanded_path(target)
  remote_path = "#{GOOGLE_DRIVE_REMOTE}#{cloud_file['remote_path']}"
  success = system('rclone', 'copyto', remote_path, target_path)
  if success
    add_log('success', "Cloud file restored: #{cloud_file['name']}")
    session[:flash] = { 'status' => 'success', 'message' => "Cloud file restored to #{target_path}." }
  else
    add_log('error', "Cloud restore failed for #{cloud_file['name']}")
    session[:flash] = { 'status' => 'error', 'message' => 'Could not restore the cloud file.' }
  end
  redirect '/cloud_files'
end

post '/cloud/:id/restore' do
  file = load_cloud_files.find { |item| item['id'] == params[:id] }
  halt 404, 'Cloud file not found' unless file

  target = params[:target].to_s.strip
  halt 400, 'Restore target is required' if target.empty?

  begin
    target_path = expanded_path(target)
    target_path = File.join(target_path, File.basename(file['name'])) if File.directory?(target)
    FileUtils.mkdir_p(File.dirname(target_path))

    overwrite = params[:overwrite] == '1'
    if File.exist?(target_path) && !overwrite
      session[:flash] = { 'status' => 'error', 'message' => 'Restore target already exists. Enable overwrite to replace it.' }
    else
      remote_path = "#{GOOGLE_DRIVE_REMOTE}#{file['remote_path']}"
      success = system('rclone', 'copyto', remote_path, target_path)
      if success && File.exist?(target_path)
        add_log('success', "Cloud file restored: #{file['name']}")
        session[:flash] = { 'status' => 'success', 'message' => "Cloud file restored to #{target_path}." }
      else
        raise SystemCallError, 'rclone could not download the cloud file'
      end
    end
  rescue SystemCallError, ArgumentError => e
    add_log('error', "Cloud restore failed for #{file['name']}: #{e.message}")
    session[:flash] = { 'status' => 'error', 'message' => "Cloud restore failed: #{e.message}" }
  end
  redirect '/'
end

post '/cloud/:id/delete' do
  file = load_cloud_files.find { |item| item['id'] == params[:id] }
  halt 404, 'Cloud file not found' unless file

  remote_path = "#{GOOGLE_DRIVE_REMOTE}#{file['remote_path']}"
  success = system('rclone', 'deletefile', remote_path)
  if success
    CONFIG_MUTEX.synchronize do
      save_cloud_files(load_cloud_files.reject { |item| item['id'] == params[:id] })
    end
    add_log('info', "Cloud file deleted: #{file['name']}")
    session[:flash] = { 'status' => 'success', 'message' => 'Cloud file deleted.' }
  else
    add_log('error', "Cloud delete failed for #{file['name']}")
    session[:flash] = { 'status' => 'error', 'message' => 'Could not delete the cloud file.' }
  end
  redirect '/'
end

post '/archive/zip' do
  source = expanded_path(params[:source])
  destination = expanded_path(params[:destination])

  begin
    raise ArgumentError, 'Шлях до файлу обов’язковий' if source.to_s.strip.empty?
    raise Errno::ENOENT, "Файл не існує: #{source}" unless File.file?(source)

    FileUtils.mkdir_p(destination)
    raise ArgumentError, 'Папку призначення неможливо записати' unless File.writable?(destination)

    archive_name = "#{Sanitize.basename(File.basename(source, '.*'))}-#{Time.now.strftime('%Y%m%d-%H%M%S')}.zip"
    archive_path = File.join(destination, archive_name)

    Zip::File.open(archive_path, create: true) do |zip|
      zip.add(File.basename(source), source)
    end

    add_log('success', "Створено ZIP-файл: #{archive_path}")
    session[:flash] = { 'status' => 'success', 'message' => "ZIP-файл створено: #{archive_path}" }
  rescue Errno::ENOENT, ArgumentError, Zip::Error, SystemCallError => e
    add_log('error', "Створення ZIP не вдалося: #{e.message}")
    session[:flash] = { 'status' => 'error', 'message' => e.message }
  end
  redirect '/'
end

post '/archive/unzip' do
  zip_path = expanded_path(params[:zip_path])
  target = expanded_path(params[:target])

  begin
    raise ArgumentError, 'Шлях до ZIP-файлу обов’язковий' if zip_path.to_s.strip.empty?
    raise Errno::ENOENT, "ZIP-файл не існує: #{zip_path}" unless File.file?(zip_path)

    FileUtils.mkdir_p(target)
    restored = 0
    Zip::File.open(zip_path) do |zip|
      zip.each do |entry|
        next if entry.directory?

        destination = File.expand_path(entry.name, target)
        prefix = File.expand_path(target)
        raise ArgumentError, "Небезпечний запис в архіві: #{entry.name}" unless destination.start_with?(prefix + File::SEPARATOR)

        FileUtils.mkdir_p(File.dirname(destination))
        if !File.exist?(destination) || params[:overwrite] == '1'
          entry.extract(destination) { true }
          restored += 1
        end
      end
    end

    add_log('success', "ZIP розпаковано: #{zip_path}")
    session[:flash] = { 'status' => 'success', 'message' => "Розпаковано #{restored} файл(ів) у #{target}" }
  rescue Errno::ENOENT, ArgumentError, Zip::Error, SystemCallError => e
    add_log('error', "Розпакування ZIP не вдалося: #{e.message}")
    session[:flash] = { 'status' => 'error', 'message' => e.message }
  end
  redirect '/'
end

post '/cache/archive' do
  begin
    record = archive_file(params[:source])
    session[:flash] = { 'status' => 'success', 'message' => "Архів створено: #{record['name']}" }
  rescue Errno::ENOENT, ArgumentError, Zip::Error, SystemCallError => e
    add_log('error', "Архівація не вдалася: #{e.message}")
    session[:flash] = { 'status' => 'error', 'message' => e.message }
  end
  redirect '/'
end

post '/cache/:id/restore' do
  record = load_cache_files.find { |item| item['id'] == params[:id] }
  halt 404, 'Archived file not found' unless record

  target = params[:target].to_s.strip
  target = record['original_path'] if target.empty?
  archive_path = record['archive_path']
  halt 404, 'Archive is missing' unless File.exist?(archive_path)

  begin
    target_path = expanded_path(target)
    if File.directory?(target_path)
      restore_name = record['restore_name'] || File.basename(record['original_path'])
      target_path = File.join(target_path, restore_name)
    end
    FileUtils.mkdir_p(File.dirname(target_path))

    if File.exist?(target_path) && params[:overwrite] != '1'
      session[:flash] = { 'status' => 'error', 'message' => 'Файл вже існує. Увімкніть заміну.' }
    else
      restored = 0
      Zip::File.open(archive_path) do |zip|
        zip.each do |entry|
          next if entry.directory?

          File.binwrite(target_path, entry.get_input_stream.read)
          restored += 1
        end
      end
      add_log('success', "Файл відновлено з кешу: #{record['name']}")
      session[:flash] = { 'status' => 'success', 'message' => "Відновлено #{restored} файл у #{target_path}" }
    end
  rescue Zip::Error, SystemCallError, ArgumentError => e
    add_log('error', "Відновлення з кешу не вдалося: #{e.message}")
    session[:flash] = { 'status' => 'error', 'message' => e.message }
  end
  redirect '/'
end

post '/cache/:id/delete' do
  record = nil
  CONFIG_MUTEX.synchronize do
    files = load_cache_files
    record = files.find { |item| item['id'] == params[:id] }
    halt 404, 'Cached archive not found' unless record
    File.delete(record['archive_path']) if File.exist?(record['archive_path'])
    save_cache_files(files.reject { |item| item['id'] == params[:id] })
  end
  add_log('info', "Кешований архів видалено: #{record['name']}")
  session[:flash] = { 'status' => 'success', 'message' => 'Архів видалено з кешу.' }
  redirect '/'
end

def archive_file(source_path)
  raise ArgumentError, 'Файл для резервного копіювання не вказано' if source_path.to_s.strip.empty?

  source = expanded_path(source_path)
  raise Errno::ENOENT, "Файл не існує: #{source}" unless File.file?(source)

  stamp = Time.now.strftime('%Y%m%d-%H%M%S')
  archive_name = "#{Sanitize.basename(File.basename(source, '.*'))}-#{stamp}-#{SecureRandom.hex(3)}.zip"
  archive_path = File.join(CACHE_DIR, archive_name)

  Zip::File.open(archive_path, create: true) do |zip|
    zip.add(File.basename(source), source)
  end

  record = {
    'id' => SecureRandom.uuid,
    'name' => archive_name,
    'original_path' => source,
    'archive_path' => archive_path,
    'created_at' => Time.now.iso8601,
    'size' => File.size(archive_path)
  }

  CONFIG_MUTEX.synchronize do
    files = load_cache_files
    files.unshift(record)
    save_cache_files(files)
  end
  add_log('success', "Файл заархівовано в кеш: #{archive_name}")
  record
end

post '/uploads' do
  begin
    FileUtils.mkdir_p(UPLOADS_DIR)
    raise ArgumentError, 'Файл для завантаження не вибрано' unless params[:file][:tempfile].nil?

    original_filename = params[:file][:filename]
    tempfile = params[:file][:tempfile]
    target_path = File.join(UPLOADS_DIR, original_filename)

    FileUtils.mkdir_p(UPLOADS_DIR)
    FileUtils.mv(tempfile.path, target_path)

    add_log('success', "Файл завантажено: #{original_filename}")
    session[:flash] = { 'status' => 'success', 'message' => "Файл завантажено: #{original_filename}" }
  rescue ArgumentError, SystemCallError => e
    add_log('error', "Завантаження файлу не вдалося: #{e.message}")
    session[:flash] = { 'status' => 'error', 'message' => e.message }
  end
  redirect '/'
end

get '/uploads' do
  @uploads = Dir.glob(File.join(UPLOADS_DIR, '*')).map { |path| File.basename(path) }
  erb :uploads
end

post '/uploads/delete' do
  filename = params[:filename]
  file_path = File.join(UPLOADS_DIR, filename)

  if File.exist?(file_path)
    File.delete(file_path)
    add_log('info', "Завантажений файл видалено: #{filename}")
    session[:flash] = { 'status' => 'success', 'message' => "Файл видалено: #{filename}" }
  else
    add_log('error', "Не вдалося знайти файл для видалення: #{filename}")
    session[:flash] = { 'status' => 'error', 'message' => "Не вдалося знайти файл для видалення: #{filename}" }
  end
  redirect '/uploads'
end

post '/uploads/extract' do
  filename = params[:filename]
  file_path = File.join(UPLOADS_DIR, filename)

  unless File.exist?(file_path)
    session[:flash] = { 'status' => 'error', 'message' => "Файл не знайдено: #{filename}" }
    redirect '/uploads'
    return
  end

  target_dir = File.join(UPLOADS_DIR, File.basename(filename, '.*'))
  FileUtils.mkdir_p(target_dir)

  begin
    restored = 0
    Zip::File.open(file_path) do |zip|
      zip.each do |entry|
        next if entry.directory?

        destination = File.join(target_dir, entry.name)
        FileUtils.mkdir_p(File.dirname(destination))
        entry.extract(destination) { restored += 1 }
      end
    end
    add_log('success', "Файл розпаковано: #{filename} (всього файлів: #{restored})")
    session[:flash] = { 'status' => 'success', 'message' => "Файл розпаковано: #{filename} (всього файлів: #{restored})" }
  rescue Zip::Error, SystemCallError => e
    add_log('error', "Розпакування файлу не вдалося: #{e.message}")
    session[:flash] = { 'status' => 'error', 'message' => "Розпакування файлу не вдалося: #{e.message}" }
  end
  redirect '/uploads'
end

post '/upload/cache' do
  upload = params[:file]
  begin
    FileUtils.mkdir_p(UPLOADS_DIR)
    raise ArgumentError, 'Файл для завантаження не вибрано' unless upload && upload[:tempfile]

    original_name = File.basename(upload[:filename].to_s)
    raise ArgumentError, 'Назва файлу порожня' if original_name.empty?

    stored_name = "#{SecureRandom.hex(8)}-#{Sanitize.basename(original_name)}"
    stored_path = File.join(UPLOADS_DIR, stored_name)
    FileUtils.cp(upload[:tempfile].path, stored_path)

    record = archive_file(stored_path)
    record['name'] = original_name
    record['original_path'] = stored_path
    record['restore_name'] = original_name

    CONFIG_MUTEX.synchronize do
      files = load_cache_files
      current = files.find { |item| item['id'] == record['id'] }
      current.merge!(record) if current
      save_cache_files(files)
    end

    session[:flash] = { 'status' => 'success', 'message' => "Файл завантажено та заархівовано: #{original_name}" }
  rescue Errno::ENOENT, ArgumentError, Zip::Error, SystemCallError => e
    add_log('error', "Завантаження файлу не вдалося: #{e.message}")
    session[:flash] = { 'status' => 'error', 'message' => e.message }
  end
  redirect '/'
end

post '/upload/unzip' do
  upload = params[:file]
  target = expanded_path(params[:target])
  begin
    FileUtils.mkdir_p(UPLOADS_DIR)
    raise ArgumentError, 'ZIP-файл для завантаження не вибрано' unless upload && upload[:tempfile]

    filename = File.basename(upload[:filename].to_s)
    raise ArgumentError, 'Назва ZIP-файлу порожня' if filename.empty?
    raise ArgumentError, 'Вкажіть папку відновлення' if target.to_s.strip.empty?

    zip_path = File.join(UPLOADS_DIR, "#{SecureRandom.hex(8)}-#{Sanitize.basename(filename)}")
    FileUtils.cp(upload[:tempfile].path, zip_path)
    FileUtils.mkdir_p(target)

    restored = 0
    Zip::File.open(zip_path) do |zip|
      zip.each do |entry|
        next if entry.directory?

        destination = File.expand_path(entry.name, target)
        prefix = File.expand_path(target)
        raise ArgumentError, "Небезпечний запис в архіві: #{entry.name}" unless destination.start_with?(prefix + File::SEPARATOR)

        FileUtils.mkdir_p(File.dirname(destination))
        if !File.exist?(destination) || params[:overwrite] == '1'
          entry.extract(destination) { true }
          restored += 1
        end
      end
    end

    session[:flash] = { 'status' => 'success', 'message' => "Розпаковано #{restored} файл(ів) у #{target}" }
  rescue Errno::ENOENT, ArgumentError, Zip::Error, SystemCallError => e
    add_log('error', "Розпакування завантаженого ZIP не вдалося: #{e.message}")
    session[:flash] = { 'status' => 'error', 'message' => e.message }
  end
  redirect '/'
end
