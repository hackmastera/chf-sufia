class GenericWorkIndexer < CurationConcerns::WorkIndexer

  def generate_solr_document
    super.tap do |doc|
      %w(additional_credit inscription date_of_work).each do |field|
        entries = remove_duplicates(field)
        doc[ActiveFedora.index_field_mapper.solr_name(field, :stored_searchable)] = entries.map { |entry| entry.display_label }
      end
      unless object.physical_container.nil?
        require_dependency Rails.root.join('lib','chf','utils','parse_fields')
        doc[ActiveFedora.index_field_mapper.solr_name("physical_container", :stored_searchable)] = CHF::Utils::ParseFields.display_physical_container(object.physical_container)
      end

      makers = %w(artist author addressee creator_of_work contributor engraver interviewee interviewer manufacturer photographer printer_of_plates publisher)
      maker_facet = makers.map { |field| object.send(field) }.flatten.uniq
      doc[ActiveFedora.index_field_mapper.solr_name('maker_facet', :facetable)] = maker_facet

      places = %W{place_of_interview place_of_manufacture place_of_publication place_of_creation}
      place_facet = places.map { |field| object.send(field) }.flatten.uniq
      doc[ActiveFedora.index_field_mapper.solr_name('place_facet', :facetable)] = place_facet

      doc[ActiveFedora.index_field_mapper.solr_name('year_facet', type: :integer)] = DateValues.new(object).expanded_years
    end
  end

  private
    def remove_duplicates(field)
      entries = object.send(field).to_a
      entries.uniq! {|e| e.id} # can return nil
      entries
    end
end
