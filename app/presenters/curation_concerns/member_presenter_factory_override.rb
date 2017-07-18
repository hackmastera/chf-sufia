# We're actually overriding from the sufia-set Sufia::FileSetPresenter, to our
# own. to_prepare seems necessary to make it stick in dev.
CurationConcerns::MemberPresenterFactory.file_presenter_class = CHF::FileSetPresenter

# And we also need to set the work_presenter_class, so it comes back from
# GenericWork#member_presenters. This is actually a custom CHF one despite the
# namespace.
CurationConcerns::MemberPresenterFactory.work_presenter_class = CurationConcerns::GenericWorkShowPresenter

# These overrides are taken from Plum's EfficientMemberPresenterFactory,
# https://github.com/pulibrary/plum/blob/f979e6688e7ddac446c1747fc0ee986aeb150869/app/factories/efficient_member_presenter_factory.rb
CurationConcerns::MemberPresenterFactory.class_eval do
  # Override to get all member solr docs in one solr query, rather than getting them one at a time in a presenter factory
  def member_presenters(ids = ordered_ids, presenter_class = composite_presenter_class)
    @member_presenters ||=
      begin
        ordered_docs.select { |x| ids.include?(x.id) }.map do |doc|
          presenter_class.new(doc, *presenter_factory_arguments)
        end
      end
  end

  def ordered_docs
    @ordered_docs ||= begin
                       ActiveFedora::SolrService.query("{!join from=ordered_targets_ssim to=id}proxy_in_ssi:#{id}", rows: 100_000).map { |x| SolrDocument.new(x) }.sort_by { |x| ordered_ids.index(x.id) }
                     end
  end

end
