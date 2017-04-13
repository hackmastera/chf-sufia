module CurationConcerns
  class GenericWorkShowPresenter < Sufia::WorkShowPresenter
    # There's no such thing as self.terms in the presenter anymore.

    delegate :genre_string, :medium, :physical_container, :creator_of_work,
      :artist, :author, :addressee, :interviewee, :interviewer,
      :manufacturer, :photographer, :place_of_interview,
      :place_of_manufacture, :place_of_creation, :place_of_publication,
      :extent, :division, :series_arrangement, :rights_holder,
      :credit_line, :additional_credit, :file_creator, :admin_note,
      :inscription, :date_of_work, :engraver, :printer_of_plates,
      :additional_title,
      to: :solr_document

    def rights_icon(identifier = rights.first)
      # schema allows multiple rights, we only use one.
      # we have added our own metadata to the liceneses.yml that the CC
      # class doens't really have accessors for, we'll kinda hack it.
      case CurationConcerns::LicenseService.new.authority.find(identifier).fetch("category", nil)
      when "in_copyright"
        "rightsstatements-InC.Icon-Only.dark.svg"
      when "no_copyright"
        "rightsstatements-NoC.Icon-Only.dark.svg"
      else
        "rightsstatements-Other.Icon-Only.dark.svg"
      end
    end

    def rights_url(identifier = rights.first)
      # we use resolvable urls already
      identifier
    end

    def rights_icon_label(identifier = rights.first)
      # we have added our own metadata to the liceneses.yml that the CC
      # class doens't really have accessors for, we'll kinda hack it.
      CurationConcerns::LicenseService.new.authority.find(identifier).fetch("short_label_html", "").html_safe
    end


  end
end
