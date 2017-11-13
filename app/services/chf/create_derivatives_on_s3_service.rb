module CHF
  # Commpletely overridden, from scratch, from CurationConcerns.
  # https://github.com/samvera/curation_concerns/blob/v1.7.8/app/jobs/create_derivatives_job.rb

  # We completely reimplement ourselves. the existing implementation was not
  # super useful, although we copy and paste some parts. We:
  #
  # 1) Assume runnning on a server NOT the app server, get file from fedora, and
  #    make sure to clean up temporary working copy.
  # 2) push to S3 (under key "#{file_set_id}_checksum#_{file_checksum}/derivative_file_name"). That file_set_ids are equally distributed hex makes this a good S3 key.
  #     checksum is used to make cached values self-busting if file changes. If caller already has
  #     the checksum, pass it in to avoid an expensive lookup.
  # 3) Use optimal settings for a small sized thumbnail, currently use vips
  #    instead of im/gm, it's much faster and uses less RAM.
  # 4) For "thumb" type derivatives, create a 2x width version for use in srcset
  #
  # This service itself has info on what image derivatives to create, it's no longer
  # going through the hydra derivatives architecture.
  #
  # This has to be called AFTER the file is really added to fedora, _should_ be
  # because of how it's called by sufia 7 stack.
  # See https://bibwild.wordpress.com/2017/07/11/on-hooking-into-sufiahyrax-after-file-has-been-uploaded/
  #     https://github.com/samvera/curation_concerns/blob/1d5246ebb8bccae0a385280eda10a7dbdc1d517d/app/jobs/characterize_job.rb#L22
  #
  # Also provides some class methods for file name calculation.
  #
  # By default it will create and write the derivatives whether they exist or not,
  # initialize with `.new(lazy: true)` to only write if not already present on S3 under expected file name.
  #
  # If you only want to create SOME derivatives, you can pass one or more
  # "styles:" and/or "typse:" to _initializer_. Can be combined with lazy.
  #
  #     CreateDerivativesOnS3Service.new(file_set, file_id, only_styles: "thumb").call
  #     CreateDerivativesOnS3Service.new(file_set, file_id, only_types: ["large_dl", "medium_dl"]).call
  #
  # We use some multi-threaded concurrency to create each derivative in parallel, inside
  # this class.
  #
  # POSSIBLE IMPRVOVEMENT: Switch to ruby-vips instead of shell out to vips command line.
  #  See: https://github.com/jcupitt/libvips/issues/777#issuecomment-337831511
  class CreateDerivativesOnS3Service
    WORKING_DIR_PARENT = CHF::Env.lookup(:derivative_job_tmp_dir)

    IMAGE_TYPES = {
      # Thumb-type widths in pixels are based on our CSS, the sizes we'll need
      # to display on actual pages. May have to change if CSS changes. If you change
      # them, you'll have to re-gen relevant derivatives to get them to have new sizes.

      # small thumb for multiple images on show page. These are tricky cause they
      # are really different sizes responsively, but we just pick one to resize to
      # as standard for now.
      thumb_standard: OpenStruct.new(width: ImageServiceHelper::THUMB_BASE_WIDTHS[:standard], style: :thumb).freeze,

      # giant thumb for big hero image on show page
      thumb_hero: OpenStruct.new(width: ImageServiceHelper::THUMB_BASE_WIDTHS[:large], style: :thumb).freeze,

      # thumbs on viewer list
      thumb_mini: OpenStruct.new(width: ImageServiceHelper::THUMB_BASE_WIDTHS[:mini], style: :thumb).freeze,


      # downloadable ones at sizes we just picked

      dl_large: OpenStruct.new(width: ImageServiceHelper::DOWNLOAD_WIDTHS[:large], label: "Large JPG", style: :download).freeze,
      dl_medium: OpenStruct.new(width: ImageServiceHelper::DOWNLOAD_WIDTHS[:medium], label: "Medium JPG", style: :download).freeze,
      dl_small: OpenStruct.new(width: ImageServiceHelper::DOWNLOAD_WIDTHS[:small], label: "Small JPG", style: :download).freeze,
      dl_full_size: OpenStruct.new(width: nil, label: "Original-size JPG", style: :download).freeze,

      # compressed TIFF disabled for now, needs testing to make sure
      # our staging server can handle it, and decision if we really want
      # to take the S3 space.
      # https://github.com/jcupitt/libvips/issues/777
      #tiff_compressed:  OpenStruct.new(label: "Original", style: :compressed_tiff).freeze
    }.freeze

    class_attribute :acl
    self.acl = 'public-read'

    class_attribute :cache_control
    self.cache_control = "max-age=31536000" # one year in seconds.

    # Using Aws::S3 directly appeared to give us a lot faster bulk upload
    # than via fog.
    def self.s3_bucket!
      s3_resource.bucket(CHF::Env.lookup!('derivative_s3_bucket'))
    end

    def self.s3_path(file_set_id:, file_checksum:, filename_key:, suffix:)
      "#{file_set_id}_checksum#{file_checksum}/#{Pathname.new(filename_key).sub_ext(suffix)}"
    end

    def self.valid_s3_keys
      @valid_s3_keys ||= IMAGE_TYPES.collect do |key, config|
        if config.style == :thumb
          [key.to_s, "#{key}_2X"]
        else
          key.to_s
        end
      end.flatten.freeze
    end

    # filename_base, if provided, is used to make more human-readable
    # 'save as' download file names, and triggers content-disposition: attachment.
    #
    # These can be slow-ish to create due to creating a signed url.
    def self.s3_url(file_set_id:, file_checksum:, filename_key:, suffix:, filename_base: nil)
      obj = s3_bucket!.object(s3_path(file_set_id: file_set_id, file_checksum: file_checksum, filename_key: filename_key, suffix: suffix))

      if filename_base
        # secure URL supplies kind of security, assuming the app won't generate
        # this link unless you have access. But we haven't really ensured that
        # universally or made secure links everywhere, so this is not yet security.
        obj.presigned_url(:get,
                          expires_in: 3.days.to_i, # no hurry
                          response_content_disposition: "attachment; filename=\"#{filename_base}_#{filename_key}.#{suffix.sub(/^\./, '')}\"")
      else
        obj.public_url
      end
    end

    # Creating a new Aws::S3::Resource is surprisingly costly, create a global
    # one and cache it.
    def self.s3_resource
      @s3_resource ||= Aws::S3::Resource.new(
        credentials: Aws::Credentials.new(CHF::Env.lookup('aws_access_key_id'), CHF::Env.lookup('aws_secret_access_key')),
        region: CHF::Env.lookup!('derivative_s3_bucket_region')
      )
    end
    self.s3_resource

    attr_reader :file_set, :file_id, :lazy, :thread_pool, :only_styles, :only_types

    # @param [FileSet] file_set
    # @param [String] file_id identifier for a Hydra::PCDM::File
    def initialize(file_set, file_id, file_checksum: nil, lazy: false, only_styles: nil, only_types: nil)
      @file_set = file_set
      @file_id = file_id
      @file_checksum = file_checksum
      @lazy = !!lazy
      @only_styles = Array(only_styles).collect(&:to_s) if only_styles
      @only_types = Array(only_types).collect(&:to_s) if only_types
    end

    # If not already set, we have to fetch from fedora, which is kinda slow with AF on wells.
    def file_checksum
      @file_checksum ||= Hydra::PCDM::File.find(file_id).checksum.value
    end

    # We set working dir state for duration of this method so we don't need to pass
    # it to helper methods, definitely not thread-safe, don't share instances
    # between threads, you weren't going to anyway.
    def call
      # copied from upstream,but don't understand why needed, shouldn't the operations
      # themselves just be smart enough to do this guard?
      return if file_set.video? && !CurationConcerns.config.enable_ffmpeg

      futures = []

      # mktmpdir will clean up tmp dir and all it's contents for us
      Dir.mktmpdir("fileset_#{file_set.id}_", WORKING_DIR_PARENT) do |temp_dir|
        @working_dir = temp_dir
        @working_original_path = CHF::GetFedoraBytestreamService.new(file_id, local_path: File.join(@working_dir, "original")).get

        if file_set.image?
          # custom CHF image derivatives

          IMAGE_TYPES.each_pair do |key, defn|
            next if only_styles && only_styles.include?(defn.style.to_s)
            next if only_types && only_types.include?(key.to_s)
            if defn.style == :thumb || defn.style == :download
              futures << create_jpg_derivative(width: defn.width, filename: key.to_s, style: defn.style)

              # 2x for srcset on thumbs
              if defn.style == :thumb && defn.width
                futures << create_jpg_derivative(width: defn.width * 2, filename: "#{key.to_s}_2X", style: defn.style)
              end
            elsif defn.style == :compressed_tiff && file_set.mime_type == "image/tiff"
              futures << create_compressed_tiff(filename: key.to_s)
            end
          end

          futures.compact.each(&:value!)
          futures.clear

          # TODO nope, get rid of this, for just our own derivatives here.
          #file_set.create_derivatives(working_original_path)
        else
          # We COULD still try do this default behavior calling #create_derivatives on
          # fileset, to get any superclass stack derivatives from sufia, say PDF
          # related and such. But we're not for now, we don't use em, don't do it,
          # if we want em, we should copy the kinds of derivativds we want here, and
          # do em right.
          # file_set.create_derivatives(working_original_path)
        end
      end
    ensure
      @working_dir = nil
      @working_original_path = nil
    end

    protected

    def working_dir
      @working_dir || (raise TypeError.new("unexpected nil @working_dir"))
    end

    def working_original_path
      @working_original_path || (raise TypeError.new("Unexpected nil @working_original_path"))
    end

    # create and push to s3.
    #
    # returns nil (if nothing to do, in lazy) or a Future
    #
    # For thumbnails, we use more aggressive image conversion parameters, as opposed
    # to downloads. Later, thumbs might also apply some cropping to enforce maximum
    # aspect ratios. For thumbnail aggressive conversion parameters, some background:
    #     * http://www.imagemagick.org/Usage/thumbnails/
    #     * https://developers.google.com/speed/docs/insights/OptimizeImages
    #     * http://libvips.blogspot.com/2013/11/tips-and-tricks-for-vipsthumbnail.html
    #     * https://github.com/jcupitt/libvips/issues/775
    def create_jpg_derivative(width:, filename:, style:)
      output_path = Pathname.new(working_dir).join(filename.to_s).sub_ext(".jpg").to_s
      s3_obj = self.class.s3_bucket!.object(self.class.s3_path(file_set_id: file_set.id, file_checksum: file_checksum, filename_key: filename, suffix: ".jpg"))

      sRGB_profile_path = Rails.root.join("vendor", "icc", "sRGB2014.icc").to_s

      if lazy && s3_obj.exists?
        return nil
      end

      vips_jpg_params = if style.to_s == "thumb"
        "[Q=85,interlace,optimize_coding,strip]"
      else
        # could be higher Q for downloads if we want, but we don't right now
        # We do avoid striping metadata, no 'strip' directive.
        "[Q=85,interlace,optimize_coding]"
      end

      extra_args = if style.to_s == "thumb"
        # for thumbs, ensure convert to sRGB and strip embedded profile,
        # as browsers assume sRGB.
        ["--eprofile", sRGB_profile_path, "--delete"]
      else
        []
      end

      # if we're not resizing, way more convenient to use a different
      # vips command line.
      args = if width
        # Due to bug in vips, we need to provide a height constraint, we make
        # really huge one million pixels so it should not come into play, and
        # we're constraining proportionally by width.
        # https://github.com/jcupitt/libvips/issues/781
        [
          "vipsthumbnail",
          working_original_path,
          *extra_args,
          "--size", "#{width}x1000000",
          "-o", "#{output_path}#{vips_jpg_params}"
        ]
      else
        [ "vips", "copy",
          working_original_path,
          *extra_args,
          "#{output_path}#{vips_jpg_params}"
        ]
      end

      Concurrent::Future.execute(executor: Concurrent.global_io_executor) do
        TTY::Command.new(printer: :null).run(*args)
        s3_obj.upload_file(output_path,
                           acl: acl,
                           content_type: "image/jpeg",
                           content_disposition: ("attachment" if style != :thumb),
                           cache_control: cache_control)
      end
    end


    # IM/GM crash our system using unholy amounts of RAM trying to operate on
    # very big TIFFs for anything at all. VIPS with correct compression args
    # (predictor=horizontal as below) needs to be tested to make sure it won't.
    def create_compressed_tiff(filename:)
      output_path = Pathname.new(working_dir).join(filename.to_s).sub_ext(".tif").to_s
      s3_obj = self.class.s3_bucket!.object(self.class.s3_path(file_set_id: file_set.id, file_checksum: file_checksum, filename_key: filename, suffix: ".tif"))

      if lazy && s3_obj.exists?
        return nil
      end

      Concurrent::Future.execute(executor: Concurrent.global_io_executor) do
        TTY::Command.new(printer: :null).run(
          "vips", "copy",
          "#{working_original_path}[predictor=horizontal,compression=deflate]",
          output_path
        )
        s3_obj.upload_file(output_path,
                           acl: acl,
                           content_type: "image/tiff",
                           content_disposition: "attachment",
                           cache_control: cache_control)
      end
    end

  end
end