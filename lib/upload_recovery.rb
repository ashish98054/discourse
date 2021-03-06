class UploadRecovery
  def initialize(dry_run: false)
    @dry_run = dry_run
  end

  def recover(posts = Post)
    posts.where("raw LIKE '%upload:\/\/%' OR raw LIKE '%href=%'").find_each do |post|
      begin
        analyzer = PostAnalyzer.new(post.raw, post.topic_id)

        analyzer.cooked_stripped.css("img", "a").each do |media|
          if media.name == "img"
            if dom_class = media["class"]
              if (Post.white_listed_image_classes & dom_class.split).count > 0
                next
              end
            end

            orig_src = media["data-orig-src"]

            if orig_src
              if @dry_run
                puts "#{post.full_url} #{orig_src}"
              else
                recover_post_upload(post, Upload.sha1_from_short_url(orig_src))
              end
            end
          elsif media.name == "a"
            href = media["href"]

            if href && data = Upload.extract_upload_url(href)
              sha1 = data[2]

              unless upload = Upload.get_from_url(href)
                if @dry_run
                  puts "#{post.full_url} #{href}"
                else
                  recover_post_upload(post, sha1)
                end
              end
            end
          end
        end
      rescue => e
        raise e unless @dry_run
        puts "#{post.full_url} #{e.class}: #{e.message}"
      end
    end
  end

  private

  def recover_post_upload(post, sha1)
    return unless sha1.present? && sha1.length == Upload::SHA1_LENGTH

    attributes = {
      post: post,
      sha1: sha1
    }

    if Discourse.store.external?
      recover_from_s3(attributes)
    else
      recover_from_local(attributes)
    end
  end

  def recover_from_local(post:, sha1:)
    public_path = Rails.root.join("public")

    @paths ||= begin
      Dir.glob(File.join(
        public_path,
        'uploads',
        'tombstone',
        RailsMultisite::ConnectionManagement.current_db,
        'original',
        '**',
        '*.*'
      )).concat(Dir.glob(File.join(
        public_path,
        'uploads',
        RailsMultisite::ConnectionManagement.current_db,
        'original',
        '**',
        '*.*'
      )))
    end

    @paths.each do |path|
      if path =~ /#{sha1}/
        begin
          tmp = Tempfile.new
          tmp.write(File.read(path))
          tmp.rewind
          create_upload(tmp, File.basename(path), post)
        ensure
          tmp&.close
        end
      end
    end
  end

  def recover_from_s3(post:, sha1:)
    @object_keys ||= begin
      s3_helper = Discourse.store.s3_helper

      s3_helper.list("original").map(&:key).concat(
        s3_helper.list("#{FileStore::S3Store::TOMBSTONE_PREFIX}original").map(&:key)
      )
    end

    @object_keys.each do |key|
      if key =~ /#{sha1}/
        tombstone_prefix = FileStore::S3Store::TOMBSTONE_PREFIX

        if key.starts_with?(tombstone_prefix)
          old_key = key
          key = key.sub(tombstone_prefix, "")

          Discourse.store.s3_helper.copy(
            old_key,
            key,
            options: { acl: "public-read" }
          )
        end

        url = "https:#{SiteSetting.Upload.absolute_base_url}/#{key}"

        begin
          tmp = FileHelper.download(
            url,
            max_file_size: SiteSetting.max_image_size_kb.kilobytes,
            tmp_file_name: "recover_from_s3"
          )

          create_upload(tmp, File.basename(key), post) if tmp
        ensure
          tmp&.close
        end
      end
    end
  end

  def create_upload(file, filename, post)
    upload = UploadCreator.new(file, filename).create_for(post.user_id)
    post.rebake! if upload.persisted?
  end
end
