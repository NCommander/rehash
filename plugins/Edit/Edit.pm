package Slash::Edit;

use strict;
use Slash;
use Slash::Constants qw(:messages :web);
use Slash::Utility;
use Slash::Display;
use Slash::Hook;
use Data::JavaScript::Anon;

use base 'Slash::Plugin';

our $VERSION = $Slash::Constants::VERSION;

sub initEditor {
	my($self) = @_;
	my $reskey = getObject('Slash::ResKey');
	my $rkey = $reskey->key('edit-submit');
	unless ($rkey->create) {
		errorLog($rkey->errstr);
		return;
	}
}

sub getPreviewIdSessionUid {
	my($self, $session, $uid, $type) = @_;
	my $user = getCurrentUser();
	$uid ||= $user->{uid};

	my $uid_q = $self->sqlQuote($uid);
	my $type_q = $self->sqlQuote($type);
	my $session_q = $self->sqlQuote($session);
	my $anon_uid = getCurrentStatic('anonymous_coward_uid');

	my $table_extra = "";
	my $where_extra = "";
	if ($type) {
		$table_extra = ",firehose";
		$where_extra = " AND preview.preview_fhid=firehose.id AND firehose.type = $type_q";
	}

	if (isAnon($uid)) {
		return $self->sqlSelect("MAX(preview_id)", "preview $table_extra", "preview.uid = $uid_q AND session = $session_q  and active='yes' $where_extra");
	} else {
		my $user_pid = $self->sqlSelect("MAX(preview_id)", "preview $table_extra", "(preview.uid = $uid_q and active='yes') $where_extra") || 0;
		my $anon_session_pid = $self->sqlSelect("MAX(preview_id)", "preview $table_extra", "preview.uid=$anon_uid and active='yes' AND session=$session_q $where_extra") || 0;
		if ($anon_session_pid > $user_pid) {
			$self->migrateAnonPreviewToUser($anon_session_pid, $uid);
			$user_pid = $anon_session_pid;
		}
		return $user_pid;
	}
}

sub migrateAnonPreviewToUser {
	my($self, $preview_id, $uid) = @_;
	my $user = getCurrentUser();
	my $form = getCurrentForm();
	my $p = $self->getPreview($preview_id);
	if (isAnon($p->{uid})) {
		my $p_data = { uid => $uid };

		my $anon_uid = getCurrentStatic('anonymous_coward_uid');

		my $fh_data = {};
		my $fh = getObject("Slash::FireHose");
		my $fh_item = $fh->getFireHose($p->{preview_fhid});

		if ($fh_item->{name}) {
			$fh_data->{uid} = $uid;
			$p_data->{submitter} = $uid;
		}

		my $user_nick = $self->getUser($uid, 'nickname');
		my $anon_nick = $self->getUser($anon_uid, 'nickname');

		if ($fh_item->{name} eq $anon_nick) {
			$fh_data->{name} = $user_nick;
		}

		$self->setPreview($preview_id, $p_data);
		$fh->setFireHose($p->{preview_fhid}, $fh_data) if keys %$fh_data > 0;
		if ($p->{reskey} && $p->{hcanswer}) {
			$form->{hcanswer} = $p->{hcanswer};
			my $reskey = getObject('Slash::ResKey');
			my $rkey = $reskey->key('edit-submit', { reskey => $p->{reskey} });
			$rkey->touch;
		}
	}
}


sub getOrCreatePreview {
	my($self, $session) = @_;
	my $user = getCurrentUser();
	my $form = getCurrentForm();

	my $fh = getObject("Slash::FireHose");
	my $tagsdb = getObject("Slash::Tags");
	my $admindb = getObject("Slash::Admin");


	if (!$form->{from_id}) {
		my $id = $self->getPreviewIdSessionUid($session, $user->{uid}, $form->{type});
	
		if ($id && !$form->{new}) {
			return $id;
		} else {
			my $id = $self->createPreview({ uid => $user->{uid}, session => $session });
			my $preview_globjid = $self->getGlobjidCreate('preview', $id);

			my $type = $user->{is_admin} ? "story" : "submission";
			$type = $form->{type} if $user->{is_admin} && $form->{type};

			my $fhid = $fh->createFireHose({ uid => $user->{uid}, preview => "yes", type => $type, globjid => $preview_globjid });

			my $fh_data = {};
			if ($type eq 'submission') {
				my $email_known = "mailto";
				$fh_data->{email} = processSub($user->{fakeemail}, $email_known) if $user->{fakeemail};
				$fh_data->{name} = $user->{nickname};
			}
			my $p_data = { preview_fhid => $fhid };
			if ($form->{new}) {
				$p_data->{title}	= $form->{title};
				$fh_data->{title} 	= strip_attribute($form->{title});
				$p_data->{url_text} 	= $form->{url} if $form->{url};
				$p_data->{introtext} 	= $form->{introtext};
			}
			$fh->setFireHose($fhid, $fh_data) if keys %$fh_data > 0;
			$self->setPreview($id, $p_data);
			$tagsdb->createTag({
				uid => $user->{uid},
				name => 'slashdot', # XXX should be a var
				globjid => $preview_globjid,
			});
			return $id;
		}
	} else {
		my ($fh_data, $p_data);
		my $src_item = $fh->getFireHose($form->{from_id}); 
		my $id = $self->createPreview({ uid => $user->{uid} });
		my $preview_globjid = $self->getGlobjidCreate('preview', $id);
		my $preview = $self->getPreview($id);
		
		# Transfer primaryskid / tid as tags
		$self->createInitialTagsForPreview($src_item, $preview);
		
		# Transfer actual tags
		$tagsdb->transferTags($src_item->{globjid}, $preview_globjid, { src_uid => $src_item->{uid}, leave_old_activated => 1 });
		$tagsdb->transferTags($src_item->{globjid}, $preview_globjid, { leave_old_activated => 1 });

		my $chosen_hr = $tagsdb->extractChosenFromTags($preview_globjid);
		my $extracolumns = $self->getNexusExtrasForChosen($chosen_hr) || [ ];

		my $src_object = $src_item->{type} eq 'story' ? $self->getStory($src_item->{srcid}) : $self->getSubmission($src_item->{srcid});

		foreach my $extra (@$extracolumns) {
			$p_data->{$extra->[1]} = $src_object->{$extra->[1]} if $src_object->{$extra->[1]};
		}


		my $type = $user->{is_admin} && $form->{type} ne "submission" ? "story" : "submission";
		my $fhid = $fh->createFireHose({ uid => $user->{uid}, preview => "yes", type => $type, globjid => $preview_globjid });

		
		foreach (qw(introtext bodytext media title dept tid primaryskid createtime)) {
			$fh_data->{$_} = $src_item->{$_};
		}
		if ($src_item->{type} eq 'story') {
			$fh_data->{uid} = $src_item->{uid};
		} else {
			$fh_data->{uid} = $user->{uid};
		}
		$fh_data->{srcid} = $src_item->{srcid};

		$p_data->{submitter} = $src_item->{uid};

		if ($src_item->{type} ne "story" && $type eq "story") {
			my $url 	= $self->getUrl($src_item->{url_id});
			$fh_data->{introtext} = slashDisplay('formatHoseIntro', { forform =>1, introtext => $fh_data->{introtext}, item => $src_item, return_intro => 1, url => $url }, { Return => 1, Nocomm => 1 });
			$fh_data->{title} = titleCaseConvert($src_item->{title});
			$fh_data->{introtext} = quoteFixIntrotext($fh_data->{introtext});
			$fh_data->{createtime} = $admindb->findTheTime('','');
		} 

		if ($src_item->{type} eq 'story') {
			my $story = $self->getStory($src_item->{srcid});
			$p_data->{neverdisplay} = 1 if $story->{neverdisplay};
			if ($story->{discussion}) {
				my $disc = $self->getDiscussion($story->{discussion});
				$p_data->{commentstatus} = $disc->{commentstatus};
			}
		}
		$p_data->{title} = $fh_data->{title} || "";
		$p_data->{introtext} =  $fh_data->{introtext};
		$p_data->{preview_fhid} = $fhid;
		$p_data->{src_fhid} = $src_item->{id};
		$p_data->{subid} = $src_item->{srcid} if $src_item->{type} eq 'submission';


		$fh->setFireHose($fhid, $fh_data);

		$self->setPreview($id, $p_data);
		$preview = $self->getPreview($id);
		return $id;
			
	}
}

sub createInitialTagsForPreview {
	my($self, $item, $preview) = @_;
	my $user = getCurrentUser();
	return if !$preview || !$item || !$item->{id} || !$preview->{preview_id};

	my @tids;
	push @tids, $item->{tid} if $item->{tid};
	if ($item->{primaryskid}) {
		my $nexus = $self->getNexusFromSkid($item->{primaryskid});
		push @tids, $nexus if $nexus;
	}

	if ($item->{type} eq 'story') {
		my $tids = $self->getTopiclistForStory($item->{srcid});
		foreach (@$tids) {
			push @tids, $_;
		}
	}
	my $tree = $self->getTopicTree();
	my $tagsdb = getObject('Slash::Tags');
	my %tt = ( ); # topic tagnames
	for my $tid (@tids) {
		my $kw = $tree->{$tid}{keyword};
		next unless $tagsdb->tagnameSyntaxOK($kw); # must be a valid tagname
		$tt{$kw} = 1;
	}
	for my $tagname (sort keys %tt) {
		$tagsdb->createTag({ name => $tagname, table => 'preview', id => $preview->{preview_id} });
	}
}

sub determineAllowedTypes {
	my $user = getCurrentUser();
	my @types = ('submission');
	push @types, "journal" if !$user->{is_anon};
	push @types, "story" if $user->{is_admin};
	return @types;
}

sub determineDefaultType {
	my $user = getCurrentUser();
	$user->{is_admin} ? 'story' : 'submission';
}

sub detectSubType {
	my($self, $text) = @_;

	my $html_count;
	$html_count++ while $text =~ /<[^a\/]/ig;

	return $html_count ? 'html' : 'plain';
}

sub savePreview {
	my($self, $options) = @_;
	my $user = getCurrentUser();
	my $form = getCurrentForm();
	my $fh = getObject("Slash::FireHose");
	my $admindb = getObject("Slash::Admin");
	my $tagsdb = getObject("Slash::Tags");

	return if !$form->{id};
	
	my $preview = $self->getPreview($form->{id});
	return if !$preview && $preview->{preview_id};
	
	my $p_item = $fh->getFireHose($preview->{preview_fhid});

	#XXXEdit check if user / or eventually session has access to this preview
	return if $user->{uid} != $preview->{uid};

	my($p_data, $fh_data);

	$p_data->{title}	= $form->{title};
	$p_data->{introtext}	= $form->{introtext};
	$fh_data->{createtime}	= $form->{createtime} if $form->{createtime};

	if ($user->{is_anon} && $form->{hcanswer} && $form->{reskey}) {
		$p_data->{hcanswer} = $form->{hcanswer};
		$p_data->{reskey}   = $form->{reskey};
	}

	if ($p_item->{type} eq 'story') {
		$p_data->{bodytext} 		= $form->{bodytext};
		$p_data->{commentstatus} 	= $form->{commentstatus};
		$p_data->{neverdisplay} 	= $form->{display} ? '' : 1;
		
		$fh_data->{uid}		= $form->{uid};
		
		# XXXEdit maybe only use findTheTime for story type?

		$fh_data->{createtime} 	= $admindb->findTheTime($form->{createtime}, $form->{fastforward});
		$fh_data->{media} 	= $form->{media};
		$fh_data->{dept} 	= $form->{dept};
		$fh_data->{bodytext}	= $form->{bodytext};
		
		$fh_data->{dept} =~ s/[-\s]+/-/g;
		$fh_data->{dept} =~ s/^-//;
		$fh_data->{dept} =~ s/-$//;
		$fh_data->{dept} =~ s/ /-/gi;
	}

	if ($p_item->{type} eq 'submission') {
		my $email_known = "";
		$email_known = "mailto" if $form->{email} eq $user->{fakeemail};
		$fh_data->{email} = processSub(strip_attribute($form->{email}), $email_known);
		$fh_data->{name} = strip_html($form->{name});

		# XXXEdit eventually perhaps look for video tag when setting this too
		$fh_data->{mediatype} = $form->{url} =~ /youtube.com|video.google.com/ ? "video" : "none";

		$p_data->{url_text} = $form->{url} if $form->{url};
		$p_data->{sub_type} = $self->detectSubType($form->{introtext});
		if ($form->{url} && $form->{title}) {
			if (validUrl($form->{url})) {
				my $url_data = {
					url		=> fudgeurl($form->{url}),
					initialtitle	=> strip_notags($form->{subj})
				};

				$fh_data->{url_id} = $self->getUrlCreate($url_data);
			}
		}
		my $fh_data->{uid} ||= $form->{name}
			? getCurrentUser('uid')
			: getCurrentStatic('anonymous_coward_uid');
	}
	$fh_data->{'-createtime'} = "NOW()" if !$fh_data->{createtime};

	$fh_data->{title} 	= strip_attribute($form->{title});
	$fh_data->{media} 	= $form->{media};
	$fh_data->{introtext}	= $form->{introtext};

	if ($p_item->{type} eq 'story') {	
		for my $field (qw( introtext bodytext media)) {
			local $Slash::Utility::Data::approveTag::admin = 2;

		# XXXEdit check this
		#	$fh_data->{$field} = $slashdb->autoUrl($form->{section}, $fh_data->{$field});
			$fh_data->{$field} = cleanSlashTags($fh_data->{$field});
			$fh_data->{$field} = strip_html($fh_data->{$field});
			$fh_data->{$field} = slashizeLinks($fh_data->{$field});
			$fh_data->{$field} = parseSlashizedLinks($fh_data->{$field});
			$fh_data->{$field} = balanceTags($fh_data->{$field});
		}
	} elsif ($p_item->{type} eq 'submission') {
		$fh_data->{introtext} = fixStory($form->{introtext}, { sub_type => $p_data->{sub_type} } );
		print STDERR "SUB TYPE: $p_data->{sub_type}\n";
	}
	
	my $chosen_hr = $tagsdb->extractChosenFromTags($p_item->{globjid});
	my $rendered_hr = $self->renderTopics($chosen_hr);
	print STDERR "RENDERED: ".Dumper($rendered_hr);
	my $primaryskid = $self->getPrimarySkidFromRendered($rendered_hr);
	print STDERR "PRIMARYSKID: $primaryskid\n";;
	my $tids = $self->getTopiclistFromChosen($chosen_hr);

	my $tid = $tids->[0];

	$fh_data->{tid} = $tid;
	$fh_data->{primaryskid} = $primaryskid;
	
	my $extracolumns = $self->getNexusExtrasForChosen($chosen_hr) || [ ];

	foreach my $extra (@$extracolumns) {
		$p_data->{$extra->[1]} = strip_nohtml($form->{$extra->[1]}) if $form->{$extra->[1]};
	}
	
	$self->setPreview($preview->{preview_id}, $p_data);
	$fh->setFireHose($preview->{preview_fhid}, $fh_data);

}

sub showEditor {
	my($self, $options) = @_;
	my $constants = getCurrentStatic();
	my $user = getCurrentUser();
	my $form = getCurrentForm();
	$options ||= {};

	my $reskey = getObject('Slash::ResKey');
	my $skey = $reskey->session;

	my $session = $form->{session} || $skey->sessionkey();

	my $admindb = getObject('Slash::Admin');

	my $preview_id = $self->getOrCreatePreview($session);
	my $editor;
	my $preview_info;
	my $similar_stories;
	my $storyref = {};

	$preview_info .=  "PREVIEW ID: $preview_id";

	my $preview = $self->getPreview($preview_id);
	$preview->{dept} = $form->{dept};

	my $fh     = getObject("Slash::FireHose");
	my $tagsdb = getObject("Slash::Tags");

	my $p_item = $fh->getFireHose($preview->{preview_fhid});

	$options->{errors} = $self->validate($preview, $p_item) if defined $form->{title} && !$form->{new} &&  !defined($options->{errors});

	my(%introtext_spellcheck, %bodytext_spellcheck, %title_spellcheck, $ispell_comments);

	if ($p_item->{type} eq 'story' && !$user->{nospell}) {
		%introtext_spellcheck = $admindb->get_ispell_comments($preview->{introtext}) if $preview->{introtext};
		%bodytext_spellcheck  = $admindb->get_ispell_comments($p_item->{bodytext})   if $p_item->{bodytext};
		%title_spellcheck     = $admindb->get_ispell_comments($p_item->{title})      if $p_item->{title};

		$ispell_comments = {
		introtext => (scalar keys %introtext_spellcheck)
			? slashDisplay("spellcheck", { words => \%introtext_spellcheck, form_element => "introtext" }, { Page => "admin", Return => 1})
			: "",
		bodytext  => (scalar keys %bodytext_spellcheck)
			? slashDisplay("spellcheck", { words => \%bodytext_spellcheck, form_element => "bodytext" }, { Page => "admin", Return => 1 })
			: "",
		title     => (scalar keys %title_spellcheck)
			? slashDisplay("spellcheck", { words => \%title_spellcheck, form_element => "title" }, { Page => "admin", Return => 1 })
			: "",
		};

		$options->{errors}{warnings}{ispellwarning} = getData('ispellwarning','','edit')
			if keys %introtext_spellcheck || keys %bodytext_spellcheck || keys %title_spellcheck;

		$similar_stories = $self->getSimilar($preview, $p_item);
		$self->setRelated(0, $storyref);
use Data::Dumper; print STDERR Dumper $storyref;
	}

	$preview_info .=  " PREVIEW FHID: $preview->{preview_fhid} SESSION: $session Item Type: $p_item->{type}<br>";

	my $showing_preview = 0;
	my $init_sprites = 0;
	my $previewed_item;

	$options->{previewing} = 0 if ($options->{errors}{critical} && keys %{$options->{errors}{critical}} > 0) || $form->{'new'};

	if ($p_item && $p_item->{title} && $preview->{introtext} && $options->{previewing}) {
		my $preview_hide = $options->{previewing} ? "" : " class='hide'";

		$showing_preview = 1 if $options->{previewing};

		$previewed_item = $fh->dispFireHose($p_item, { view_mode => 1, mode => "full" });
		$previewed_item .= slashDisplay("init_sprites", { sprite_root_id => 'editpreview'}, { Return => 1}) if $constants->{use_sprites};
	}
	
	my $authors = $self->getDescriptions('authors', '', 1);
	$authors->{$p_item->{uid}} = $self->getUser($p_item->{uid}, 'nickname') if $p_item->{uid} && !defined($authors->{$p_item->{uid}});
	my $author_select = createSelect('uid', $authors, $p_item->{uid}, 1);
		
	my $display_check = $preview->{neverdisplay} ? '' : $constants->{markup_checked_attribute};

	
	if (!$preview->{commentstatus}) {
		$preview->{commentstatus} = $constants->{defaultcommentstatus};
	}


	my $description = $self->getDescriptions('commentcodes_extended');
	my $commentstatus_select = createSelect('commentstatus', $description, $preview->{commentstatus}, 1);
	my $chosen_hr = $tagsdb->extractChosenFromTags($p_item->{globjid});
	my $extracolumns = $self->getNexusExtrasForChosen($chosen_hr) || [ ];

	my $sfids = $self->sqlSelect('value', 'preview_param', "preview_id = $preview_id and name = 'sfid'");

	my $tag_widget = slashDisplay('edit_bar', {
		item         => $p_item,
		id           => $p_item->{id},
		key          => $preview->{preview_fhid},
		key_type     => 'firehose-id',
		options      => $options->{options},
		edit_mode    => 1,
		skipvote     => 1,
		vote         => $options->{vote},
	}, { Return => 1, Page => 'firehose'});

	
	$editor .= slashDisplay('editor', { 
		id                      => $preview_id,
		fhid                    => $preview->{preview_fhid},
		preview                 => $preview, 
		item                    => $p_item,
		author_select           => $author_select,
		commentstatus_select    => $commentstatus_select,
		display_check           => $display_check,
		extras                  => $extracolumns,
		errors                  => $options->{errors},
		ispell_comments         => $ispell_comments,
		preview_shown           => $showing_preview,
		previewed_item          => $previewed_item,
		session                 => $session,
		tag_widget              => $tag_widget,
		preview_info            => $preview_info,
		nowrap                  => $options->{nowrap},
		state                   => $options->{state},
		similar_stories         => $similar_stories,
		storyref                => $storyref,
		add_related_text        => $form->{add_related},
		sfids                   => $sfids,
	 }, { Page => 'edit', Return => 1 });

	return $editor;
}

sub validate {
	my($self, $preview, $item) = @_;
	my $constants = getCurrentStatic();
	my $messages;	

	my $tagsdb = getObject("Slash::Tags");

	if ($item->{type} eq 'submission') {
		if (length($item->{title}) < 2) {
			$messages->{critical}{badsubject} = getData('badsubject','','edit');
		}

		my $message;
		my %keys_to_check = ( story => $preview->{introtext}, subj => $item->{title} );
		for (keys %keys_to_check) {
			next unless $keys_to_check{$_};
			# run through filters
			if (! filterOk('submissions', $_, $keys_to_check{$_}, \$message)) {
				$messages->{critical}{$_ . '_filter_error'} = $message;
			}
			# run through compress test
			if (! compressOk($keys_to_check{$_})) {
				$messages->{critical}{compresserror} = getData('compresserror','','edit');
			}
		}

		if ($preview->{url_text}) {
			if(!validUrl($preview->{url_text})) {
				$messages->{critical}{invalidurl} = getData("invalidurl",'','edit');
			}
			if ($item->{url_id}) {
				if ($constants->{plugin}{FireHose}) {
					my $firehose = getObject("Slash::FireHose");
					if (!$firehose->allowSubmitForUrl($item->{url_id})) {
						my $submitted_items = $firehose->getFireHoseItemsByUrl($item->{url_id});
						$messages->{critical}{duplicateurl} = getData("duplicateurl", { submitted_items => $submitted_items }, 'edit');
					}
				}
			}
		}

		if (!$preview->{introtext}) {
			$messages->{critical}{badintrotext} = getData('badintrotext','','edit');
		}
		# XXXEdit Check Nexus Extras eventually
		# XXXEdit test reskey success / failure here? or in saveItem?
	} elsif ($item->{type} eq 'story') {
		# Admin-specific errors
		if ($preview->{introtext} =~ /link to original source/i) {
			$messages->{critical}{orig_source} = getData('introtext_origsource', '', 'edit');
		}

		if (!$preview->{dept}) {
			$messages->{critical}{baddept} = getData('baddept', '', 'edit');
		}

		my $topic = $self->getTopic($item->{tid});
		if ((!$topic || !$topic->{image}) && !$item->{thumb}) {
			$messages->{critical}{noicon} = getData('noicon','','edit');
		}

		my $other_tags = $tagsdb->setGetDisplayTags($item->{id}, 'firehose-id');
		if (!$other_tags->{domain_tag}) {
			$messages->{critical}{no_domaintag} = getData('no_domaintag', '', 'edit');
		}
	}

	# XXX This is wrong. Will fix. -cbrown
        my $applied_tags = $tagsdb->getTagsByGlobjid($item->{globjid});
        $messages->{warnings}{tagwarning} = getData('tagwarning', { type => $item->{type} }, 'edit') if (!@$applied_tags);

	#use Data::Dumper;
	#print STDERR Dumper(\@messages);
	#print STDERR Dumper(\%messages);
	#return \@messages;
	return $messages;	
}

sub saveItem {
	my($self, $rkey) = @_;
	my $user = getCurrentUser();
	my $form = getCurrentForm();
	my $fh = getObject("Slash::FireHose");
	return if !$form->{id};
	
	my $preview = $self->getPreview($form->{id});
	return if !$preview && $preview->{preview_id};

	#XXXEdit check if user / or eventually session has access to this preview
	return if $user->{uid} != $preview->{uid};

	my $fhitem = $fh->getFireHose($preview->{preview_fhid});

	$preview->{dept} = $form->{dept};
	my $errors = $self->validate($preview,$fhitem);
# XXX if you use this, comment *out* the similar call in edit.pl:save()
# 	if ($rkey && !(keys %$errors)) {
# 		unless ($rkey->use) {
# 			errorLog($rkey->errstr);
# 			return;
# 		}
# 	}

	my $create_retval = 0;
	my $save_type = 'new';

	if ($fhitem && $fhitem->{id} && !(keys %{$errors->{critical}})) {
		# creating a new story

		if ($fhitem->{type} eq "story") {
			my $src_item;
			$src_item = $fh->getFireHose($preview->{src_fhid}) if $preview->{src_fhid};

			# preview based on story so save edits when done
			if ($preview->{src_fhid} && $src_item && $src_item->{type} eq 'story') {
				$create_retval = $self->editUpdateStory($preview, $fhitem);
				$save_type = 'update';
			} else {   # not based on story save new
				$create_retval = $self->editCreateStory($preview, $fhitem);
			}
		
			

		} elsif ($fhitem->{type} eq 'submission') {
			$create_retval = $self->editCreateSubmission($preview, $fhitem);
		}

		# XXX change to getData()
		$errors->{critical}{save_error} = "Save Failed" if !$create_retval;
	}

	# XXXEdit eventually make sure this is ours before setting inactive

	# XXXEdit Turn all users previews inactive at this poin? 
	if ($create_retval) {
		$self->setPreview($preview->{preview_id}, { active => 'no'});
	}
	return ($create_retval, $fhitem->{type}, $save_type, $errors, $preview);
}

sub editUpdateStory {
	my($self, $preview, $fhitem) = @_;
	my $constants = getCurrentStatic();
	my $user = getCurrentUser();
	my $admindb = getObject("Slash::Admin");
	my $tagsdb = getObject("Slash::Tags");
	my $data;
	use Data::Dumper;

	my $story = $self->getStory($fhitem->{srcid});

	my $chosen_hr = { };
	my @topics;
	push @topics, $fhitem->{tid} if $fhitem->{tid};


	$chosen_hr = $tagsdb->extractChosenFromTags($fhitem->{globjid});


	$data = {
		uid 		=> $fhitem->{uid},
		#sid
		title		=> $fhitem->{title},
		#section
		submitter	=> $preview->{submitter},
		dept		=> $fhitem->{dept},
		'time'		=> $fhitem->{createtime},
		bodytext 	=> $preview->{bodytext},
		introtext 	=> $preview->{introtext},
		#relatedtext
		media	 	=> $fhitem->{media},
		commentstatus	=> $preview->{commentstatus},
		#thumb
		-rendered	=> 'NULL',
		neverdisplay	=> $preview->{neverdisplay},
		topics_chosen	=> $chosen_hr
	};
	
	$data->{subid} = $preview->{subid} if $preview->{subid};
	$data->{fhid} = $preview->{src_fhid} if $preview->{fhid};
	
	for (qw(dept bodytext relatedtext)) {
		$data->{$_} = '' unless defined $data->{$_};  # allow to blank out
	}
		
	for my $field (qw( introtext bodytext media)) {
		local $Slash::Utility::Data::approveTag::admin = 2;

	# XXXEdit check this
	#	$data->{$field} = $slashdb->autoUrl($form->{section}, $data->{$field});
		$data->{$field} = cleanSlashTags($data->{$field});
		$data->{$field} = strip_html($data->{$field});
		$data->{$field} = slashizeLinks($data->{$field});
		$data->{$field} = parseSlashizedLinks($data->{$field});
		$data->{$field} = balanceTags($data->{$field});
	}
	
	for (qw(dept bodytext relatedtext)) {
		$data->{$_} = '' unless defined $data->{$_};  # allow to blank out
	}

	$self->setStory($story->{stoid}, $data);
	return $story->{sid};
}

sub getExtrasToSaveForChosen {
	my($self, $chosen_hr, $preview) = @_;
	my $extras = $self->getNexusExtrasForChosen($chosen_hr) || [];
	
	my $save_extras = {};

	foreach my $extra(@$extras) {
		$save_extras->{$extra->[1]} = strip_nohtml($preview->{$extra->[1]}) if $preview->{$extra->[1]};
	}
	return $save_extras;
}

sub editCreateStory {
	my($self, $preview, $fhitem) = @_;
	my $constants = getCurrentStatic();
	my $user = getCurrentUser();
	my $data;
	
	my $tagsdb = getObject("Slash::Tags");
	my $admindb = getObject("Slash::Admin");

	my $chosen_hr = { };
	my @topics;
	push @topics, $fhitem->{tid} if $fhitem->{tid};


	$chosen_hr = $tagsdb->extractChosenFromTags($fhitem->{globjid});
	my $save_extras = $self->getExtrasToSaveForChosen($chosen_hr, $preview);

	$data = {
		uid 		=> $fhitem->{uid},
		#sid
		title		=> $fhitem->{title},
		#section
		submitter	=> $preview->{submitter},
		topics_chosen	=> $chosen_hr,
		dept		=> $fhitem->{dept},
		'time'		=> $admindb->findTheTime($fhitem->{createtime}, $preview->{fastforward}),
		bodytext 	=> $preview->{bodytext},
		introtext 	=> $preview->{introtext},
		#relatedtext
		media	 	=> $fhitem->{media},
		commentstatus	=> $preview->{commentstatus},
		#thumb
		-rendered	=> 'NULL',
		neverdisplay	=> $preview->{neverdisplay},
	};

	foreach my $key (keys %$save_extras) {
		$data->{$key} = $save_extras->{$key};
	}
	
	$data->{subid} = $preview->{subid} if $preview->{subid};
	$data->{fhid} = $preview->{src_fhid} if $preview->{fhid};
	
	for (qw(dept bodytext relatedtext)) {
		$data->{$_} = '' unless defined $data->{$_};  # allow to blank out
	}
		
	for my $field (qw( introtext bodytext media)) {
		local $Slash::Utility::Data::approveTag::admin = 2;

	# XXXEdit check this
	#	$data->{$field} = $slashdb->autoUrl($form->{section}, $data->{$field});
		$data->{$field} = cleanSlashTags($data->{$field});
		$data->{$field} = strip_html($data->{$field});
		$data->{$field} = slashizeLinks($data->{$field});
		$data->{$field} = parseSlashizedLinks($data->{$field});
		$data->{$field} = balanceTags($data->{$field});
	}
	
	for (qw(dept bodytext relatedtext)) {
		$data->{$_} = '' unless defined $data->{$_};  # allow to blank out
	}

	my $sid = $self->createStory($data);
	
	if ($sid) {
		my $st = $self->getStory($sid);
		$self->setRelated($sid);
		slashHook('admin_save_story_success', { story => $data });
		my $stoid = $st->{stoid};
		my $story_globjid = $self->getGlobjidCreate('stories', $stoid); 

		# XXXEdit Do we have to worry about user editing vs author uid on transfer
		$tagsdb->transferTags($fhitem->{globjid}, $story_globjid);

		#Don't automatically signoff with new editor, this makes it automatically disapper for an admin on first refresh
		#$self->createSignoff($st->{stoid}, $data->{uid}, "saved");
		
		#XXXEdit Tags Auto save?
		my $admindb = getObject("Slash::Admin");
		if ($admindb) {
			$admindb->grantStoryPostingAchievements($data->{uid}, $data->{submitter});
			$admindb->addSpriteForSid($_);
		}

		#XXX Move this to Slash::DB
		my $sfids = $self->sqlSelect('value', 'preview_param', "name = 'sfid' and preview_id = " . $preview->{preview_id});
                if ($sfids && $stoid) {
                        $self->sqlUpdate('static_files', { stoid => $stoid, fhid => 0 }, 'fhid = ' . $preview->{preview_fhid});
                }
	}

	return $sid;
}

sub editCreateSubmission {
	my($self, $preview, $fhitem) = @_;
	my $constants = getCurrentStatic();
	my $user = getCurrentUser();
	my $gSkin = getCurrentSkin();

	my $tagsdb = getObject("Slash::Tags");
	my $chosen_hr = $tagsdb->extractChosenFromTags($fhitem->{globjid});
	my $save_extras = $self->getExtrasToSaveForChosen($chosen_hr, $preview);


	my $submission = {
		email		=> $fhitem->{email},
		#XXXEdit check handling of uid / post anon
		uid		=> $fhitem->{uid},
		name		=> $fhitem->{name},
		story		=> $fhitem->{introtext},
		subj		=> $fhitem->{title},
		tid		=> $fhitem->{tid},
		primaryskid 	=> $fhitem->{primaryskid} || $gSkin->{skid},
		mediatype	=> $fhitem->{mediatype}
		
	};

	foreach my $key (keys %$save_extras) {
		$submission->{$key} = $save_extras->{$key};
	}
	
	my $messagesub = { %$submission };

	# XXXEdit add url_id handling
	 $submission->{url_id} = $fhitem->{url_id} if $fhitem->{url_id};
	my $subid = $self->createSubmission($submission);

	$messagesub->{subid} = $subid;

	my $sub_globjid = $self->getGlobjidCreate('submissions', $subid); 
	$tagsdb->transferTags($fhitem->{globjid}, $sub_globjid);
	
	if ($submission->{url_id}) {
		my $globjid = $self->getGlobjidCreate("submissions", $messagesub->{subid});
		$self->addUrlForGlobj($submission->{url_id}, $globjid);
	}
	
	if ($messagesub->{subid} && ($fhitem->{uid} != getCurrentStatic('anonymous_coward_uid'))) {
		my $dynamic_blocks = getObject('Slash::DynamicBlocks');
		$dynamic_blocks->setUserBlock('submissions', $fhitem->{uid}) if $dynamic_blocks;
	}
	
	my $messages = getObject('Slash::Messages');
	if ($messages) {
		my $users = $messages->getMessageUsers(MSG_CODE_NEW_SUBMISSION);
		my $data  = {
			template_name	=> 'messagenew',
			subject		=> { template_name => 'messagenew_subj' },
			submission	=> $messagesub,
		};
		$messages->create($users, MSG_CODE_NEW_SUBMISSION, $data) if @$users;
	}


	return $subid;
}

sub ajaxEditorAfter {
	my($slashdb, $constants, $user, $form, $options) = @_;

	my $reskey = getObject('Slash::ResKey');
	my $skey = $reskey->session;
	print STDERR "Edit Session $skey for UID: $user->{uid} (ajax)\n";
	$skey->set_cookie;

	my $edit = getObject("Slash::Edit");
	$edit->initEditor();
	my $html_add_after = {};
	$html_add_after->{"firehose-$form->{from_id}"} = $edit->showEditor({state => 'inline'});
	my $eval_first = "\$('#firehose-$form->{from_id}').hide().addClass('edithidden').fadeTo('',1);\n";
	$eval_first .= "firehose_collapse_entry($form->{from_id});";
	return Data::JavaScript::Anon->anon_dump({
		eval_first	=> $eval_first,
		html_add_after	=> $html_add_after
	});
}

sub getSimilar {
	my($self, $preview, $fh_item, $num) = @_;
	my $story = {
		introtext  => $preview->{introtext},
		title      => $fh_item->{title},
		bodytext   => $fh_item->{bodytext},
		
	}; # XXX: sid?

	$num ||= getCurrentStatic('similarstorynumshow') || 5;
	my $similar_stories = $self->getSimilarStories($story, $num);
	if ($similar_stories && @$similar_stories) { # XXX dupe code
		for my $sim (@$similar_stories) {
			# Display a max of five words reported per story.
			$#{$sim->{words}} = 4 if $#{$sim->{words}} > 4;
			for my $word (@{$sim->{words}}) {
				# Max of 12 chars per word.
				$word = substr($word, 0, 12);
			}
			# Max of 35 char title.
			$sim->{title} = chopEntity($sim->{title}, 35);
		}
	}
	return $similar_stories;
}

sub setRelated {
	my($self, $sid, $storyref) = @_;
	my $admindb = getObject('Slash::Admin');
	my($related_sids_hr, $related_urls_hr, $related_cids_hr, $related_firehose_hr)
		= $admindb->extractRelatedStoriesFromForm(getCurrentForm());

	if ($storyref) {
		$storyref->{related_sids_hr}     = $related_sids_hr;
		$storyref->{related_urls_hr}     = $related_urls_hr;
		$storyref->{related_cids_hr}     = $related_cids_hr;
		$storyref->{related_firehose_hr} = $related_firehose_hr;
	}

	if ($sid) {
		$self->setRelatedStoriesForStory($sid,
			$related_sids_hr, $related_urls_hr,
			$related_cids_hr, $related_firehose_hr
		);
	}
}

sub ajaxUploadShowPreview {
        my ($slashdb, $constants, $user, $form, $options) = @_;

        return if (!$user->{is_admin} || !$form->{fhid});

        my $fhid_q = $slashdb->sqlQuote($form->{fhid});
        my $preview_id = $slashdb->sqlSelect('preview_id', 'preview', "preview_fhid = $fhid_q");

        my $sfid = $slashdb->sqlSelect('value', 'preview_param', "name = 'sfid' and preview_id = " . $preview_id);
        my @sfids = split(',', $sfid);
        my %sfid_data;

        foreach my $id (@sfids) {
                $sfid_data{$id} = $slashdb->sqlSelectHashref('*', 'static_files', "sfid = $id and fhid = $fhid_q");
                my $filename = $sfid_data{$id}->{name};
                my $lg_filename = $filename;
                my ($suffix) = $filename =~ /^.+(\..+)$/;
                $lg_filename =~ s/$suffix/-thumblg$suffix/;
                $sfid_data{$id}->{lg_name} = $lg_filename;

                my $md_filename = $filename;
                $md_filename =~ s/$suffix/-thumb$suffix/;
                $sfid_data{$id}->{md_filename} = $md_filename;
                $sfid_data{$id}->{md_sfid} = $slashdb->sqlSelect('sfid', 'static_files', "fhid = $fhid_q and name = '$md_filename'");
        }

        my $preview = slashDisplay('imgupload_preview', { preview_data => \%sfid_data, fhid => $form->{fhid} }, { Page => 'misc', Return => 1 });
        return Data::JavaScript::Anon->anon_dump({
                preview => $preview,
        });
}

sub ajaxUploadSetThumb {
        my ($slashdb, $constants, $user, $form, $options) = @_;

        return if (!$user->{is_admin});
        return if (!$form->{fhid});
        return if (!$form->{sfid} && !$form->{clear});

        my $sfid = $form->{sfid} || 0;
        my $sfid_q = $slashdb->sqlQuote($sfid);
        my $fhid_q = $slashdb->sqlQuote($form->{fhid});

        $slashdb->sqlUpdate(
                'firehose',
                { -thumb => $sfid_q },
                "id = $fhid_q and preview = 'yes'"
        );
}

sub DESTROY {
	my($self) = @_;
	$self->{_dbh}->disconnect if !$ENV{GATEWAY_INTERFACE} && $self->{_dbh};
}


1;

__END__
