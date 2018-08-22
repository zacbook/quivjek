#!/usr/bin/ruby
require "date"
require "json"
require "fileutils"
require "quivjek/version"
require "jekyll"
require "front_matter_parser"
require "yaml"

Jekyll::Hooks.register :site, :after_reset do |site|
  # Changed to after_reset hook to so that jekyll serve regenerates
  # quiver posts when quiver notebook is changed.

  if (ENV['APP_ENV'] != 'production')
    q = Quivjek.new(site)
    q.load_posts_from_quiver()
  end

end


class Quivjek
  # Set reasonable defaults
  NOTEBOOK_DIR = 'quiver.qvnotebook'
  POST_DIR = '_posts/quiver'
  IMG_DIR = 'images/quiver'

  def initialize( site )

    # Update config
    site.config['notebook_dir'] = NOTEBOOK_DIR unless site.config['notebook_dir']
    site.config['post_dir'] = POST_DIR unless site.config['post_dir']
    site.config['img_dir'] = IMG_DIR unless site.config['img_dir']

    # puts "#{site.config}"


    self.showhelp('The quivjek plugin requires notebook_dir be set in your _config.yml file') unless site.config.key?('notebook_dir')

    # puts "site.config"
    # puts "#{site.config}"
    # puts "#{site.config['test_package']}"
    # puts "#{site.config['test_package']['setting1']}"

    @site         = site
    @jekyll_dir   = site.source
    @notebook_dir = site.config.fetch('notebook_dir', NOTEBOOK_DIR)
    @post_dir     = File.join(@jekyll_dir, site.config.fetch('post_dir', POST_DIR))
    @img_dir     = File.join(@jekyll_dir, site.config.fetch('img_dir', POST_DIR))

  end

  def load_posts_from_quiver()

    # The post_dir and img_dir must be excluded to avoid triggering a reset
    # after writing the markdown files.
    # The below ensures that neither post_dir nor img_dir are added multiple
    # times
    @site.exclude.push(@post_dir) unless @site.exclude.include?(@post_dir)
    @site.exclude.push(@img_dir) unless @site.exclude.include?(@img_dir)


    Dir.mkdir(@post_dir) unless File.exists?(@post_dir)
    Dir.mkdir(@img_dir) unless File.exists?(@img_dir)

    # Clear out the _posts/quiver and images/q directories in case any posts or images have been renamed
    FileUtils.rm_rf Dir.glob(@post_dir + '/*')
    FileUtils.rm_rf Dir.glob(@img_dir + '/*')

    # Pass the path of each .qvnote to the copy_post method
    Dir.foreach(@notebook_dir) do |item|
      next if item == '.' or item == '..' or item == 'meta.json' or item == '.keep'
      self.copy_note(File.join(@notebook_dir, item))
    end

  end

  def showhelp(message)
    puts message.red + "\n"
    exit
  end

  def copy_note(note_dir)
    # Load the quiver note meta.json file.
    metajson = self.load_meta_json(note_dir)

    # Skip this note if tagged with draft
    metajson["tags"].each do |tag|
      return if tag == 'draft'
    end

    # Copy the notes images to the jekyll directory
    imagepath    = File.join(note_dir, "resources")
    self.copy_note_images(imagepath) if File.exist?(imagepath)

    # Load the quiver note content.json file and merge its cells.
    contentjson = self.load_content_json(note_dir)
    content     = self.merge_cells(contentjson, '')

    # Parse out optional frontmatter from the content
    parsed      = FrontMatterParser::Parser.new(:md).call(content)
    fm          = parsed.front_matter
    content     = parsed.content

    # Set some default frontmatter and combine with content
    fm = self.set_default_frontmatter(fm, metajson)
    output = fm.to_yaml + "---\n" + content

    # Write the markdown file to the jekyll dir
    filename    = self.get_filename(fm)
    File.open(File.join(@post_dir, filename), "w") { |file| file.write(output) }

  end

  def load_meta_json(dir)
    metapath    = File.join(dir, "meta.json")
    self.showhelp("meta.json doesn't exist") unless File.exist? metapath
    metajson = JSON.parse(File.read(metapath))

    return metajson
  end

  def load_content_json(dir)
    contentpath = File.join(dir, "content.json")
    self.showhelp(contentpath + "content.json doesn't exist") unless File.exist? contentpath
    contentjson = JSON.parse(File.read(contentpath))

    return contentjson
  end

  def copy_note_images(imagepath)

    # copy all images from the note's resources dir to the jekyll images/q dir
    Dir.foreach(imagepath) do |item|
      next if item == '.' or item == '..'
      FileUtils.cp(File.join(imagepath, item), @img_dir)
    end

  end

  def get_filename(fm)
    title = fm["title"].gsub(" ", "-").downcase
    date = DateTime.parse(fm["date"])

    day = "%02d" % date.day
    month = "%02d" % date.month
    year = date.year

    return "#{year}-#{month}-#{day}-#{title}.md"
  end

  def set_default_frontmatter(fm, metajson)
    # TODO: This should also set the layout of post if missing

    # If certain frontmatter is missing default to quiver metadata
    fm['title'] = metajson['title']      unless fm['title']
    fm['layout'] = 'default' unless fm['layout']

    if !fm.key?("date")
      date = DateTime.strptime(metajson["created_at"].to_s, "%s")
      fm['date'] = date.strftime('%Y-%m-%d')
    end

    fm['tags']  = metajson["tags"]
    return fm

  end

  def merge_cells(contentjson, output)
    contentjson["cells"].each do |cell|
      case cell["type"]
        when "code"
          output << "{% highlight #{cell["language"]} %}\n"
          output << "#{cell["data"]}\n"
          output << "{% endhighlight %}\n"
        when "markdown"

          c = cell["data"]

          # Scan the markdown cell for images
          images = c.scan(/!\[(.*)\]\(quiver-image-url\/(.*)\)/)
          images.each do |image|

            # Modify the image source to point to the alt tag in the images/q/ folder
            c = c.gsub(image[1], image[0])

            # Rename the image (since the image has already been copied from the qvnote folder)
            File.rename(File.join(@img_dir, image[1]), File.join(@img_dir, image[0]))
          end

          # This wants to use the img_dir, but not @img_dir, which is
          # the full file path
          # Should ideally use site.
          output << "#{c.gsub("quiver-image-url", @site.config['img_dir'])}\n"


        when "text"
          # YOLO: just concatenate HTML data
          # Put in a div indicating that markdown=0 for kramdown
          # maybe have an 'if kramdown' block here...
          # What should other parsers use?
          output << '<div markdown="0">' + "\n"
          output << "#{cell["data"]}" + "\n"
          output << '<div><br /></div>' + "\n"
          output << '</div>' + "\n"

      when "latex"
          output << '$$' + "\n"
          output << "#{cell["data"]}" + "\n"
          output << '$$' + "\n"


        else
          # This was broken because this is called before frontmatter was
          # defined
          # self.showhelp("all cells must be code or markdown types")

          puts "Unsupported cell type: #{cell['type']}"
          # puts "#{output}"


      end
      output << "\n"

    end
    return output
  end

end
