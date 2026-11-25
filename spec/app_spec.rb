require_relative 'spec_helper'
require 'tmpdir'

describe 'Backup Manager' do
  it 'renders the simplified dashboard' do
    get '/'

    expect(last_response).to be_ok
    expect(last_response.body).to include('збережених файлів')
    expect(last_response.body).to include('Додати файл для резервного копіювання')
    expect(last_response.body).to include('Відновити файл із Google Диск')
  end

  it 'rejects an archive request for a missing file' do
    post '/cache/archive', source: '/definitely/missing/file.txt'

    expect(last_response).to be_redirect
  end

  it 'archives a file and exposes it in the cache registry' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'document.txt')
      File.write(source, 'pink backup data')

      post '/cache/archive', source: source

      expect(last_response).to be_redirect
      archives = load_cache_files
      expect(archives.length).to eq(1)
      expect(File.exist?(archives.first['archive_path'])).to be(true)
      expect(archives.first['original_path']).to eq(source)
    end
  end

  it 'restores an archived file from local cache' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'document.txt')
      target = File.join(dir, 'restored.txt')
      File.write(source, 'cached content')
      record = archive_file(source)

      post "/cache/#{record['id']}/restore", target: target, overwrite: '1'

      expect(last_response).to be_redirect
      expect(File.exist?(target)).to be(true)
      expect(File.binread(target)).to eq('cached content')
    end
  end

  it 'creates a separate ZIP archive outside the cache' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'document.txt')
      destination = File.join(dir, 'archives')
      File.write(source, 'zip content')

      post '/archive/zip', source: source, destination: destination

      expect(last_response).to be_redirect
      zip_files = Dir.glob(File.join(destination, '*.zip'))
      expect(zip_files.length).to eq(1)
      Zip::File.open(zip_files.first) do |zip|
        expect(zip.read('document.txt')).to eq('zip content')
      end
    end
  end

  it 'extracts a separate ZIP archive into a target folder' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'document.txt')
      destination = File.join(dir, 'archives')
      target = File.join(dir, 'restored')
      File.write(source, 'unzip content')
      FileUtils.mkdir_p(destination)
      zip_path = File.join(destination, 'document.zip')

      Zip::File.open(zip_path, create: true) do |zip|
        zip.add('document.txt', source)
      end

      post '/archive/unzip', zip_path: zip_path, target: target, overwrite: '1'

      expect(last_response).to be_redirect
      expect(File.binread(File.join(target, 'document.txt'))).to eq('unzip content')
    end
  end

  it 'accepts an uploaded file and adds it to the cache' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'dragged.txt')
      File.write(source, 'dragged content')
      uploaded = Rack::Test::UploadedFile.new(source, 'text/plain', true)

      post '/upload/cache', file: uploaded

      expect(last_response).to be_redirect
      archives = load_cache_files
      expect(archives.length).to eq(1)
      expect(archives.first['restore_name']).to eq('dragged.txt')
      expect(File.exist?(archives.first['archive_path'])).to be(true)
    end
  end

  it 'extracts an uploaded ZIP archive' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'uploaded.zip')
      target = File.join(dir, 'restored')
      Zip::File.open(source, create: true) do |zip|
        zip.get_output_stream('from-drop.txt') { |io| io.write('dropped zip') }
      end

      post '/upload/unzip', file: Rack::Test::UploadedFile.new(source, 'application/zip', true), target: target, overwrite: '1'

      expect(last_response).to be_redirect
      expect(File.binread(File.join(target, 'from-drop.txt'))).to eq('dropped zip')
    end
  end

  it 'deletes a cached archive and its registry entry' do
    Dir.mktmpdir do |dir|
      source = File.join(dir, 'document.txt')
      File.write(source, 'data')
      record = archive_file(source)

      post "/cache/#{record['id']}/delete"

      expect(last_response).to be_redirect
      expect(load_cache_files).to be_empty
      expect(File.exist?(record['archive_path'])).to be(false)
    end
  end
end
