package Slim::Control::Queries;

# $Id:  $
#
# SqueezeCenter Copyright 2001-2007 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.

################################################################################

=head1 NAME

Slim::Control::Queries

=head1 DESCRIPTION

L<Slim::Control::Queries> implements most SqueezeCenter queries and is designed to 
 be exclusively called through Request.pm and the mechanisms it defines.

 Except for subscribe-able queries (such as status and serverstatus), there are no
 important differences between the code for a query and one for
 a command. Please check the commented command in Commands.pm.

=cut

use strict;

use Data::URIEncode qw(complex_to_query);
use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);
use URI::Escape;

use Slim::Utils::Misc qw( specified validMacAddress );
use Slim::Utils::Alarms;
use Slim::Utils::Log;
use Slim::Utils::Unicode;
use Slim::Utils::Prefs;

{
	if ($^O =~ /Win32/) {
		require Win32::DriveInfo;
	}
}

my $log = logger('control.queries');

my $prefs = preferences('server');

# Frequently used data can be cached in memory, such as the list of albums for Jive
my $cache = {};

sub alarmsQuery {
	my $request = shift;

	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['alarms']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client   = $request->client();
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $filter	 = $request->getParam('filter');
	my $alarmDOW = $request->getParam('dow');
	
	
	if ($request->paramNotOneOfIfDefined($filter, ['all', 'defined', 'enabled'])) {
		$request->setStatusBadParams();
		return;
	}
	
	my @results;

	if (defined $alarmDOW) {

		$results[0] = Slim::Utils::Alarms->newLoaded($client, $alarmDOW);

	} else {

		my $i = 0;

		$filter = 'enabled' if !defined $filter;

		for $alarmDOW (0..7) {

			my $alarm = Slim::Utils::Alarms->newLoaded($client, $alarmDOW);
			
			my $wanted = ( 
				($filter eq 'all') ||
				($filter eq 'defined' && !$alarm->undefined()) ||
				($filter eq 'enabled' && $alarm->enabled())
			);

			$results[$i++] = $alarm if $wanted;
		}
	}

	my $count = scalar @results;

	$request->addResult('fade', $prefs->client($client)->get('alarmfadeseconds'));
	$count += 0;
	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = 'alarms_loop';
		my $cnt = 0;
		
		for my $eachitem (@results[$start..$end]) {
			$request->addResultLoop($loopname, $cnt, 'dow', $eachitem->dow());
			$request->addResultLoop($loopname, $cnt, 'enabled', $eachitem->enabled());
			$request->addResultLoop($loopname, $cnt, 'time', $eachitem->time());
			$request->addResultLoop($loopname, $cnt, 'volume', $eachitem->volume());
			$request->addResultLoop($loopname, $cnt, 'url', $eachitem->playlist());
			$request->addResultLoop($loopname, $cnt, 'playlist_id', $eachitem->playlistid());
			$cnt++;
		}
	}

	$request->setStatusDone();
}

sub albumsQuery {
	my $request = shift;

	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['albums']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my %favorites;
	$favorites{'url'}    = $request->getParam('favorites_url');
	$favorites{'title'}  = $request->getParam('favorites_title');
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $tags          = $request->getParam('tags');
	my $search        = $request->getParam('search');
	my $compilation   = $request->getParam('compilation');
	my $contributorID = $request->getParam('artist_id');
	my $genreID       = $request->getParam('genre_id');
	my $trackID       = $request->getParam('track_id');
	my $year          = $request->getParam('year');
	my $sort          = $request->getParam('sort');
	my $menu          = $request->getParam('menu');
	my $insert        = $request->getParam('menu_all');
	my $to_cache      = $request->getParam('cache');
	
	if ($request->paramNotOneOfIfDefined($sort, ['new', 'album', 'artflow'])) {
		$request->setStatusBadParams();
		return;
	}

	# menu/jive mgmt
	my $menuMode = defined $menu;
	my $insertAll = $menuMode && defined $insert;

	if (!defined $tags) {
		$tags = 'l';
	}
	
	# get them all by default
	my $where = {};
	my $attr = {};
	
	# Normalize and add any search parameters
	if (defined $trackID) {
		$where->{'tracks.id'} = $trackID;
		push @{$attr->{'join'}}, 'tracks';
	}
	
	# ignore everything if $track_id was specified
	else {
	
		if ($sort && $sort eq 'new') {

			$attr->{'order_by'} = 'tracks.timestamp desc, tracks.disc, tracks.tracknum, tracks.titlesort';
			push @{$attr->{'join'}}, 'tracks';
		}
		
		if ($sort && $sort eq 'artflow') {

			$attr->{'order_by'} = Slim::Schema->resultset('Album')->fixupSortKeys('contributor.namesort,album.year,album.titlesort');
			push @{$attr->{'join'}}, 'contributor';
		}

		if (specified($search)) {
			$where->{'me.titlesearch'} = {'like', Slim::Utils::Text::searchStringSplit($search)};
		}
		
		if (defined $year) {
			$where->{'me.year'} = $year;
		}
		
		# Manage joins
		if (defined $contributorID){
		
			# handle the case where we're asked for the VA id => return compilations
			if ($contributorID == Slim::Schema->variousArtistsObject->id) {
				$compilation = 1;
			}
			else {	
				$where->{'contributorAlbums.contributor'} = $contributorID;
				push @{$attr->{'join'}}, 'contributorAlbums';
				$attr->{'distinct'} = 1;
			}			
		}
	
		if (defined $genreID){
			$where->{'genreTracks.genre'} = $genreID;
			push @{$attr->{'join'}}, {'tracks' => 'genreTracks'};
			$attr->{'distinct'} = 1;
		}
	
		if (defined $compilation) {
			if ($compilation == 1) {
				$where->{'me.compilation'} = 1;
			}
			if ($compilation == 0) {
				$where->{'me.compilation'} = [ { 'is' => undef }, { '=' => 0 } ];
			}
		}
	}
	
	# Jive menu mode, needs contributor data and only a subset of columns
	if ( $menuMode ) {
		push @{ $attr->{'join'} }, 'contributor';
		$attr->{'cols'} = [ qw(id artwork title contributor.name titlesort) ];
	}
	
	# Flatten request for lookup in cache, only for Jive menu queries
	my $cacheKey = complex_to_query($where) . complex_to_query($attr) . $menu . $tags . (defined $insert ? $insert : '');
	if ( $menuMode ) {
		if ( my $cached = $cache->{albums}->{$cacheKey} ) {
			my $copy = from_json( $cached );
			
			# Don't slice past the end of the array
			if ( $copy->{count} < $index + $quantity ) {
				$quantity = $copy->{count} - $index;
			}
		
			# Slice the full album result according to start and end
			$copy->{item_loop} = [ @{ $copy->{item_loop} }[ $index .. ( $index + $quantity ) - 1 ] ];
		
			# Change offset value
			$copy->{offset} = $index;
		
			$request->setRawResults( $copy );
			$request->setStatusDone();
		
			return;
		}
	}
	
	# use the browse standard additions, sort and filters, and complete with 
	# our stuff
	my $rs = Slim::Schema->rs('Album')->browse->search($where, $attr);

	my $count = $rs->count;

	if ($menuMode) {

		# Bug 5435, 8020
		# on "new music" queries, return the count as being 
		# the user setting for new music limit if available
		# then fall back to the block size if the pref doesn't exist
		if (defined $sort && $sort eq 'new') {
			if (!$prefs->get('browseagelimit')) {
				if ($count > $quantity) {
					$count = $quantity;
				}
			} else {
				if ($count > $prefs->get('browseagelimit')) {
					$count = $prefs->get('browseagelimit');
				}
			}
		}

		# decide what is the next step down
		# generally, we go to tracks after albums, so we get menu:track
		# from the tracks we'll go to songinfo
		my $actioncmd = $menu . 's';
		my $nextMenu = 'songinfo';
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => [$actioncmd],
					'params' => {
						'menu' => $nextMenu,
						'menu_all' => '1',
						'sort' => 'tracknum',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
				'add-hold' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'insert',
					},
					'itemsParams' => 'params',
				}		
			},
			'window' => {
				'titleStyle' => "album",
			}
		};
		
		# adapt actions to SS preference
		if (!$prefs->get('noGenreFilter') && defined $genreID) {
			$base->{'actions'}->{'go'}->{'params'}->{'genre_id'} = $genreID;
			$base->{'actions'}->{'play'}->{'params'}->{'genre_id'} = $genreID;
			$base->{'actions'}->{'add'}->{'params'}->{'genre_id'} = $genreID;
		}
		$request->addResult('base', $base);
	}
	
	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	$count += 0;

	my $totalCount = _fixCount($insertAll, \$index, \$quantity, $count);

	# now build the result
	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	my $loopname = $menuMode?'item_loop':'albums_loop';
	my $chunkCount = 0;
	$request->addResult('offset', $request->getParam('_index')) if $menuMode;

	if ($valid) {


		# first PLAY ALL item
		if ($insertAll) {
			$chunkCount = _playAll(start => $start, end => $end, chunkCount => $chunkCount, request => $request, loopname => $loopname, includeArt => 1);
		}

		# We need to know the 'No album' name so that those items
		# which have been grouped together under it do not get the
		# album art of the first album.
		# It looks silly to go to Madonna->No album and see the
		# picture of '2 Unlimited'.
		my $noAlbumName = Slim::Utils::Strings::string('NO_ALBUM');

		for my $eachitem ($rs->slice($start, $end)) {

			# Jive result formatting
			if ($menuMode) {
				
				# we want the text to be album\nartist
				my $artist = $eachitem->contributor->name;
				my $text   = $eachitem->title;
				if (defined $artist) {
					$text = $text . "\n" . $artist;
				}

				my $favorites_title = $text;
				$favorites_title =~ s/\n/ - /g;

				$request->addResultLoop($loopname, $chunkCount, 'text', $text);
				
				my $id = $eachitem->id();
				$id += 0;

				# the favorites url to be sent to jive is the album title here
				# album id would be (much) better, but that would screw up the favorite on a rescan
				# title is a really stupid thing to use, since there's no assurance it's unique
				my $url = 'db:album.titlesearch=' . $eachitem->title;

				my $params = {
					'album_id'        => $id,
					'favorites_url'   => $url,
					'favorites_title' => $favorites_title,
				};
				
				if (defined $contributorID) {
					$params->{artist_id} = $contributorID;
				}

				unless ($sort && $sort eq 'new') {
					$params->{textkey} = substr($eachitem->titlesort, 0, 1),
				}

				$request->addResultLoop($loopname, $chunkCount, 'params', $params);

				# artwork if we have it
				if ($eachitem->title ne $noAlbumName &&
				    defined(my $iconId = $eachitem->artwork())) {
					$iconId += 0;
					$request->addResultLoop($loopname, $chunkCount, 'icon-id', $iconId);
				}
			}
			
			# "raw" result formatting (for CLI or JSON RPC)
			else {
				$request->addResultLoop($loopname, $chunkCount, 'id', $eachitem->id);
				$tags =~ /l/ && $request->addResultLoop($loopname, $chunkCount, 'album', $eachitem->title);
				$tags =~ /y/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'year', $eachitem->year);
				$tags =~ /j/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'artwork_track_id', $eachitem->artwork);
				$tags =~ /t/ && $request->addResultLoop($loopname, $chunkCount, 'title', $eachitem->rawtitle);
				$tags =~ /i/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'disc', $eachitem->disc);
				$tags =~ /q/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'disccount', $eachitem->discc);
				$tags =~ /w/ && $request->addResultLoopIfValueDefined($loopname, $chunkCount, 'compilation', $eachitem->compilation);
				if ($tags =~ /a/) {
					my @artists = $eachitem->artists();
					if ( blessed( $artists[0] ) ) {
						$request->addResultLoopIfValueDefined($loopname, $chunkCount, 'artist', $artists[0]->name());
					}
				}
			}
			
			$chunkCount++;
		}

		if ($menuMode) {
			# Add Favorites as the last item, if applicable
			my $lastChunk;
			if ( $end == $count - 1 && $chunkCount < $request->getParam('_quantity') ) {
				$lastChunk = 1;
			}
			($chunkCount, $totalCount) = _jiveAddToFavorites(lastChunk => $lastChunk, start => $start, chunkCount => $chunkCount, listCount => $totalCount, request => $request, loopname => $loopname, favorites => \%favorites, includeArt => 1);
		}
	}
	elsif ($totalCount > 1 && $menuMode) {
		($chunkCount, $totalCount) = _jiveAddToFavorites(lastChunk => 1, start => $start, chunkCount => $chunkCount, listCount => $totalCount, request => $request, loopname => $loopname, favorites => \%favorites, includeArt => 1);	
	}

	if ($totalCount == 0 && $menuMode) {
		# this is an empty resultset
		_jiveNoResults($request);
	} else {
		$request->addResult('count', $totalCount);
	}


	# Cache data as JSON to speed up the cloning of it later, this is faster
	# than using Storable
	if ( $to_cache && $menuMode ) {
		$cache->{albums}->{$cacheKey} = to_json( $request->getResults() );
	}

	$request->setStatusDone();
}


sub artistsQuery {
	my $request = shift;

	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['artists']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $search   = $request->getParam('search');
	my $year     = $request->getParam('year');
	my $genreID  = $request->getParam('genre_id');
	my $genreString  = $request->getParam('genre_string');
	my $trackID  = $request->getParam('track_id');
	my $albumID  = $request->getParam('album_id');
	my $menu     = $request->getParam('menu');
	my $insert   = $request->getParam('menu_all');
	my $to_cache = $request->getParam('cache');
	my %favorites;
	$favorites{'url'} = $request->getParam('favorites_url');
	$favorites{'title'} = $request->getParam('favorites_title');
	
	# menu/jive mgmt
	my $menuMode = defined $menu;
	my $insertAll = $menuMode && defined $insert;
	my $allAlbums = defined $genreID;
	
	# get them all by default
	my $where = {};
	
	# sort them
	my $attr = {
		'order_by' => 'me.namesort',
		'distinct' => 'me.id'
	};
	
	# same for the VA search
	my $where_va = {'me.compilation' => 1};
	my $attr_va = {};

 	# Normalize any search parameters
 	if (specified($search)) {
 
 		$where->{'me.namesearch'} = {'like', Slim::Utils::Text::searchStringSplit($search)};
 	}

	my $rs;
	my $cacheKey;

	# Manage joins 
	if (defined $trackID) {
		$where->{'contributorTracks.track'} = $trackID;
		push @{$attr->{'join'}}, 'contributorTracks';
		
		# don't use browse here as it filters VA...
		$rs = Slim::Schema->rs('Contributor')->search($where, $attr);
	}
	else {
		if (defined $genreID) {
			$where->{'genreTracks.genre'} = $genreID;
			push @{$attr->{'join'}}, {'contributorTracks' => {'track' => 'genreTracks'}};
			
			$where->{'contributorTracks.role'} = { 'in' => Slim::Schema->artistOnlyRoles };
			
			$where_va->{'genreTracks.genre'} = $genreID;
			push @{$attr_va->{'join'}}, {'tracks' => 'genreTracks'};
		}
		
		if (defined $albumID || defined $year) {
		
			if (defined $albumID) {
				$where->{'track.album'} = $albumID;
				
				$where_va->{'me.id'} = $albumID;
			}
			
			if (defined $year) {
				$where->{'track.year'} = $year;
				
				$where_va->{'track.year'} = $year;
			}
			
			if (!defined $genreID) {
				# don't need to add track again if we have a genre search
				push @{$attr->{'join'}}, {'contributorTracks' => 'track'};

				# same logic for VA search
				if (defined $year) {
					push @{$attr->{'join'}}, 'track';
				}
			}
		}
		
		# Flatten request for lookup in cache, only for Jive menu queries
		$cacheKey = complex_to_query($where) . complex_to_query($attr) . $menu . (defined $insert ? $insert : '');
		if ( $menuMode ) {
			if ( my $cached = $cache->{artists}->{$cacheKey} ) {
				my $copy = from_json( $cached );

				# Don't slice past the end of the array
				if ( $copy->{count} < $index + $quantity ) {
					$quantity = $copy->{count} - $index;
				}

				# Slice the full album result according to start and end
				$copy->{item_loop} = [ @{ $copy->{item_loop} }[ $index .. ( $index + $quantity ) - 1 ] ];

				# Change offset value
				$copy->{offset} = $index;

				$request->setRawResults( $copy );
				$request->setStatusDone();

				return;
			}
		}
		
		# use browse here
		$rs = Slim::Schema->rs('Contributor')->browse( undef, $where )->search( {}, $attr );
	}
	
	my $count = $rs->count;
	my $totalCount = $count || 0;

	# Various artist handling. Don't do if pref is off, or if we're
	# searching, or if we have a track
	my $count_va = 0;

	if ($prefs->get('variousArtistAutoIdentification') &&
		!defined $search && !defined $trackID) {

		# Only show VA item if there are any
		$count_va =  Slim::Schema->rs('Album')->search($where_va, $attr_va)->count;

		# fix the index and counts if we have to include VA
		$totalCount = _fixCount($count_va, \$index, \$quantity, $count);

		# don't add the VA item on subsequent queries
		$count_va = ($count_va && !$index);
	}

	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to albums after artists, so we get menu:album
		# from the albums we'll go to tracks
		my $actioncmd = $menu . 's';
		my $nextMenu = 'track';
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => [$actioncmd],
					'params' => {
						menu     => $nextMenu,
						menu_all => '1',
					},
					'itemsParams' => 'params'
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params'
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params'
				},
				'add-hold' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'insert',
					},
					'itemsParams' => 'params'
				},
			},
			# style correctly the window that opens for the action element
			'window' => {
				'menuStyle'  => 'album',
				'titleStyle' => 'artists',
			}
		};
		if (!$prefs->get('noGenreFilter') && defined $genreID) {
			$base->{'actions'}->{'go'}->{'params'}->{'genre_id'} = $genreID;
			$base->{'actions'}->{'play'}->{'params'}->{'genre_id'} = $genreID;
			$base->{'actions'}->{'add'}->{'params'}->{'genre_id'} = $genreID;
		}
		$request->addResult('base', $base);
	}


	$totalCount = _fixCount($insertAll, \$index, \$quantity, $totalCount);

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	$count += 0;

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	my $loopname = $menuMode?'item_loop':'artists_loop';
	my $chunkCount = 0;
	$request->addResult( 'offset', $request->getParam('_index') ) if $menuMode;

	if ($valid) {

		my @data = $rs->slice($start, $end);
			
		# Various artist handling. Don't do if pref is off, or if we're
		# searching, or if we have a track
		if ($count_va) {
			unshift @data, Slim::Schema->variousArtistsObject;
		}

		# first PLAY ALL item
		if ($insertAll) {
			$chunkCount = _playAll(start => $start, end => $end, chunkCount => $chunkCount, request => $request, loopname => $loopname);
		}


		for my $obj (@data) {

			next if !$obj;
			my $id = $obj->id();
			$id += 0;

			if ($menuMode){
				$request->addResultLoop($loopname, $chunkCount, 'text', $obj->name);

				# the favorites url to be sent to jive is the artist name here
				my $url = 'db:contributor.namesearch=' . $obj->name;

				my $params = {
					'favorites_url'   => $url,
					'favorites_title' => $obj->name,
					'artist_id' => $id, 
					'textkey' => substr($obj->namesort, 0, 1),
				};

				$request->addResultLoop($loopname, $chunkCount, 'params', $params);
			}
			else {
				$request->addResultLoop($loopname, $chunkCount, 'id', $id);
				$request->addResultLoop($loopname, $chunkCount, 'artist', $obj->name);
			}

			$chunkCount++;
		}
		
		if ($menuMode) {
			# Add Favorites as the last item, if applicable
			my $lastChunk = 0;
			if ( $end == $count - 1 && $chunkCount < $request->getParam('_quantity') ) {
				$lastChunk = 1;
			}

			if ($allAlbums) {
				($chunkCount, $totalCount) = _jiveGenreAllAlbums(start => $start, end => $end, lastChunk => $lastChunk, listCount => $totalCount, chunkCount => $chunkCount, request => $request, loopname => $loopname, genreID => $genreID, genreString => $genreString );
			}

			($chunkCount, $totalCount) = _jiveAddToFavorites(lastChunk => ($lastChunk == 1), listCount => $totalCount, chunkCount => $chunkCount, request => $request, loopname => $loopname, favorites => \%favorites);
		}
	}
	elsif ($totalCount > 1 && $menuMode) {
		($chunkCount, $totalCount) = _jiveAddToFavorites(lastChunk => 1, listCount => $totalCount, chunkCount => $chunkCount, request => $request, loopname => $loopname, favorites => \%favorites);
	}

	if ($totalCount == 0 && $menuMode) {
		# this is an empty resultset
		_jiveNoResults($request);
	} else {
		$request->addResult('count', $totalCount);
	}
	
	# Cache data as JSON to speed up the cloning of it later, this is faster
	# than using Storable
	if ( $to_cache && $menuMode ) {
		$cache->{artists}->{$cacheKey} = to_json( $request->getResults() );
	}

	$request->setStatusDone();
}


sub cursonginfoQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['duration', 'artist', 'album', 'title', 'genre',
			'path', 'remote', 'current_title']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	my $client = $request->client();

	# get the query
	my $method = $request->getRequest(0);
	my $url = Slim::Player::Playlist::url($client);
	
	if (defined $url) {

		if ($method eq 'path') {
			
			$request->addResult("_$method", $url);

		} elsif ($method eq 'remote') {
			
			$request->addResult("_$method", 
				Slim::Music::Info::isRemoteURL($url));
			
		} elsif ($method eq 'current_title') {
			
			$request->addResult("_$method", 
				Slim::Music::Info::getCurrentTitle($client, $url));

		} else {

			my $track = Slim::Schema->rs('Track')->objectForUrl($url);

			if (!blessed($track) || !$track->can('secs')) {

				logBacktrace("Couldn't fetch object for URL: [$url] - skipping track.");

			} else {

				if ($method eq 'duration') {

					$request->addResult("_$method", $track->secs() || 0);

				} elsif ($method eq 'album' || $method eq 'artist' || $method eq 'genre') {

					$request->addResult("_$method", $track->$method->name || 0);

				} else {

					$request->addResult("_$method", $track->$method() || 0);
				}
			}
		}
	}

	$request->setStatusDone();
}


sub connectedQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['connected']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();
	
	$request->addResult('_connected', $client->connected() || 0);
	
	$request->setStatusDone();
}


sub debugQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['debug']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $category = $request->getParam('_debugflag');

	if ( !defined $category || !Slim::Utils::Log->isValidCategory($category) ) {

		$request->setStatusBadParams();
		return;
	}

	my $categories = Slim::Utils::Log->allCategories;
	
	if (defined $categories->{$category}) {
	
		$request->addResult('_value', $categories->{$category});
		
		$request->setStatusDone();

	} else {

		$request->setStatusBadParams();
	}
}


sub displayQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['display']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();
	
	my $parsed = $client->parseLines($client->curLines());

	$request->addResult('_line1', $parsed->{line}[0] || '');
	$request->addResult('_line2', $parsed->{line}[1] || '');
		
	$request->setStatusDone();
}


sub displaynowQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['displaynow']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();

	$request->addResult('_line1', $client->prevline1());
	$request->addResult('_line2', $client->prevline2());
		
	$request->setStatusDone();
}


sub displaystatusQuery_filter {
	my $self = shift;
	my $request = shift;

	# we only listen to display messages
	return 0 if !$request->isCommand([['displaynotify']]);

	# retrieve the clientid, abort if not about us
	my $clientid = $request->clientid();
	return 0 if !defined $clientid;
	return 0 if $clientid ne $self->clientid();

	my $subs  = $self->getParam('subscribe');
	my $type  = $request->getParam('_type');
	my $parts = $request->getParam('_parts');

	# check displaynotify type against subscription ('showbriefly', 'update', 'bits', 'all')
	if ($subs eq $type || ($subs eq 'bits' && $type ne 'showbriefly') || $subs eq 'all') {

		my $pd = $self->privateData;

		# display forwarding is suppressed for this subscriber source
		return 0 if exists $parts->{ $pd->{'format'} } && !$parts->{ $pd->{'format'} };

		# don't send updates if there is no change
		return 0 if ($type eq 'update' && !$self->client->display->renderCache->{'screen1'}->{'changed'});

		# store display info in subscription request so it can be accessed by displaystatusQuery
		$pd->{'type'}  = $type;
		$pd->{'parts'} = $parts;

		# execute the query immediately
		$self->__autoexecute;
	}

	return 0;
}

sub displaystatusQuery {
	my $request = shift;
	
	$log->info("displaystatusQuery()");

	# check this is the correct query
	if ($request->isNotQuery([['displaystatus']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $subs  = $request->getParam('subscribe');

	# return any previously stored display info from displaynotify
	if (my $pd = $request->privateData) {

		my $client= $request->client;
		my $format= $pd->{'format'};
		my $type  = $pd->{'type'};
		my $parts = $type eq 'showbriefly' ? $pd->{'parts'} : $client->display->renderCache;

		$request->addResult('type', $type);

		# return screen1 info if more than one screen
		$parts = $parts->{'screen1'} if $parts->{'screen1'};

		if ($subs eq 'bits' && $parts->{'bitsref'}) {
			
			# send the display bitmap if it exists (graphics display)
			use bytes;

			my $bits = ${$parts->{'bitsref'}};
			if ($parts->{'scroll'}) {
				$bits |= substr(${$parts->{'scrollbitsref'}}, 0, $parts->{'overlaystart'}[$parts->{'scrollline'}]);
			}

			$request->addResult('bits', MIME::Base64::encode_base64($bits) );
			$request->addResult('ext', $parts->{'extent'});

		} elsif ($format eq 'cli') {

			# format display for cli
			for my $c (keys %$parts) {
				next unless $c =~ /^(line|center|overlay)$/;
				for my $l (0..$#{$parts->{$c}}) {
					$request->addResult("$c$l", $parts->{$c}[$l]) if ($parts->{$c}[$l] ne '');
				}
			}

		} elsif ($format eq 'jive') {

			# send display to jive from one of the following components
			if (my $ref = $parts->{'jive'} && ref $parts->{'jive'}) {
				if ($ref eq 'CODE') {
					$request->addResult('display', $parts->{'jive'}->() );
				} elsif($ref eq 'ARRAY') {
					$request->addResult('display', { 'text' => $parts->{'jive'} });
				} else {
					$request->addResult('display', $parts->{'jive'} );
				}
			} else {
				$request->addResult('display', { 'text' => $parts->{'line'} || $parts->{'center'} });
			}
		}

	} elsif ($subs =~ /showbriefly|update|bits|all/) {
		# new subscription request - add subscription, assume cli or jive format for the moment
		$request->privateData({ 'format' => $request->source eq 'CLI' ? 'cli' : 'jive' }); 

		my $client = $request->client;

		$log->info("adding displaystatus subscription $subs");

		if ($subs eq 'bits') {

			if ($client->display->isa('Slim::Display::NoDisplay')) {
				# there is currently no display class, we need an emulated display to generate bits
				Slim::bootstrap::tryModuleLoad('Slim::Display::EmulatedSqueezebox2');
				if ($@) {
					$log->logBacktrace;
					logError("Couldn't load Slim::Display::EmulatedSqueezebox2: [$@]");

				} else {
					# swap to emulated display
					$client->display->forgetDisplay();
					$client->display( Slim::Display::EmulatedSqueezebox2->new($client) );
					$client->display->init;				
					# register ourselves for execution and a cleanup function to swap the display class back
					$request->registerAutoExecute(0, \&displaystatusQuery_filter, \&_displaystatusCleanupEmulated);
				}

			} elsif ($client->display->isa('Slim::Display::EmulatedSqueezebox2')) {
				# register ourselves for execution and a cleanup function to swap the display class back
				$request->registerAutoExecute(0, \&displaystatusQuery_filter, \&_displaystatusCleanupEmulated);

			} else {
				# register ourselves for execution and a cleanup function to clear width override when subscription ends
				$request->registerAutoExecute(0, \&displaystatusQuery_filter, sub {
					$client->display->widthOverride(1, undef);
					if ( !Slim::Control::Request::hasSubscribers('displaystatus', $client->id) ) {
						$log->info("last listener - suppressing display notify");
						$client->display->notifyLevel(0);
					}
					$client->update;
				});
			}

			# override width for new subscription
			$client->display->widthOverride(1, $request->getParam('width'));

		} else {
			$request->registerAutoExecute(0, \&displaystatusQuery_filter, sub {
				if ( !Slim::Control::Request::hasSubscribers('displaystatus', $client->id) ) {
					$log->info("last listener - suppressing display notify");
					$client->display->notifyLevel(0);
				}
			});
		}

		if ($subs eq 'showbriefly') {
			$client->display->notifyLevel(1);
		} else {
			$client->display->notifyLevel(2);
			$client->update;
		}
	}
	
	$request->setStatusDone();
}

# cleanup function to disable display emulation.  This is a named sub so that it can be suppressed when resubscribing.
sub _displaystatusCleanupEmulated {
	my $request = shift;
	my $client  = $request->client;

	if ( !Slim::Control::Request::hasSubscribers('displaystatus', $client->id) ) {
		$log->info("last listener - swapping back to NoDisplay class");
		$client->display->forgetDisplay();
		$client->display( Slim::Display::NoDisplay->new($client) );
		$client->display->init;
	}
}


sub genresQuery {
	my $request = shift;

	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['genres']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $search        = $request->getParam('search');
	my $year          = $request->getParam('year');
	my $contributorID = $request->getParam('artist_id');
	my $albumID       = $request->getParam('album_id');
	my $trackID       = $request->getParam('track_id');
	my $menu          = $request->getParam('menu');
	my $insert        = $request->getParam('menu_all');
	my $to_cache      = $request->getParam('cache');
	
	# menu/jive mgmt
	my $menuMode  = defined $menu;
	my $insertAll = $menuMode && defined $insert;
		
	# get them all by default
	my $where = {};
	
	# sort them
	my $attr = {
		'distinct' => 'me.id'
	};

	# Normalize and add any search parameters
	if (specified($search)) {

		$where->{'me.namesearch'} = {'like', Slim::Utils::Text::searchStringSplit($search)};
	}

	# Manage joins
	if (defined $trackID) {
			$where->{'genreTracks.track'} = $trackID;
			push @{$attr->{'join'}}, 'genreTracks';
	}
	else {
		# ignore those if we have a track. 
		
		if (defined $contributorID){
		
			# handle the case where we're asked for the VA id => return compilations
			if ($contributorID == Slim::Schema->variousArtistsObject->id) {
				$where->{'album.compilation'} = 1;
				push @{$attr->{'join'}}, {'genreTracks' => {'track' => 'album'}};
			}
			else {	
				$where->{'contributorTracks.contributor'} = $contributorID;
				push @{$attr->{'join'}}, {'genreTracks' => {'track' => 'contributorTracks'}};
			}
		}
	
		if (defined $albumID || defined $year){
			if (defined $albumID) {
				$where->{'track.album'} = $albumID;
			}
			if (defined $year) {
				$where->{'track.year'} = $year;
			}
			push @{$attr->{'join'}}, {'genreTracks' => 'track'};
		}
	}
	
	# Flatten request for lookup in cache, only for Jive menu queries
	my $cacheKey = complex_to_query($where) . complex_to_query($attr) . $menu . (defined $insert ? $insert : '');
	if ( $menuMode ) {
		if ( my $cached = $cache->{genres}->{$cacheKey} ) {
			my $copy = from_json( $cached );

			# Don't slice past the end of the array
			if ( $copy->{count} < $index + $quantity ) {
				$quantity = $copy->{count} - $index;
			}

			# Slice the full album result according to start and end
			$copy->{item_loop} = [ @{ $copy->{item_loop} }[ $index .. ( $index + $quantity ) - 1 ] ];

			# Change offset value
			$copy->{offset} = $index;

			$request->setRawResults( $copy );
			$request->setStatusDone();

			return;
		}
	}

	my $rs = Slim::Schema->resultset('Genre')->browse->search($where, $attr);

	my $count = $rs->count;

	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to artists after genres, so we get menu:artist
		# from the artists we'll go to albums
		my $actioncmd = $menu . 's';
		my $nextMenu = 'album';
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => [$actioncmd],
					'params' => {
						menu     => $nextMenu,
						menu_all => '1',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
				'add-hold' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'insert',
					},
					'itemsParams' => 'params',
				},
			},
			window => { titleStyle => 'genres', },
		};
		$request->addResult('base', $base);

	}
	
	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	$count += 0;
	my $totalCount = _fixCount($insertAll, \$index, \$quantity, $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = $menuMode?'item_loop':'genres_loop';
		my $chunkCount = 0;
		$request->addResult( 'offset', $request->getParam('_index') ) if $menuMode;
		
		if ($insertAll) {
			$chunkCount = _playAll(start => $start, end => $end, chunkCount => $chunkCount, request => $request, loopname => $loopname);
		}
		for my $eachitem ($rs->slice($start, $end)) {
			
			my $id = $eachitem->id();
			$id += 0;
			
			if ($menuMode) {
				$request->addResultLoop($loopname, $chunkCount, 'text', $eachitem->name);
				
				# here the url is the genre name
				my $url = 'db:genre.namesearch=' . $eachitem->name;
				my $params = {
					'genre_id'        => $id,
					'genre_string'    => $eachitem->name,
					'textkey'         => substr($eachitem->namesort, 0, 1),
					'favorites_url'   => $url,
					'favorites_title' => $eachitem->name,
				};

				$request->addResultLoop($loopname, $chunkCount, 'params', $params);
			}
			else {
				$request->addResultLoop($loopname, $chunkCount, 'id', $id);
				$request->addResultLoop($loopname, $chunkCount, 'genre', $eachitem->name);
			}
			$chunkCount++;
		}
	}

	if ($totalCount == 0 && $menuMode) {
		_jiveNoResults($request);
	} else {
		$request->addResult('count', $totalCount);
	}
	
	# Cache data as JSON to speed up the cloning of it later, this is faster
	# than using Storable
	if ( $to_cache && $menuMode ) {
		$cache->{genres}->{$cacheKey} = to_json( $request->getResults() );
	}

	$request->setStatusDone();
}


sub infoTotalQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['info'], ['total'], ['genres', 'artists', 'albums', 'songs']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $entity = $request->getRequest(2);

	if ($entity eq 'albums') {
		$request->addResult("_$entity", Slim::Schema->count('Album'));
	}

	if ($entity eq 'artists') {
		$request->addResult("_$entity", Slim::Schema->rs('Contributor')->browse->count);
	}

	if ($entity eq 'genres') {
		$request->addResult("_$entity", Slim::Schema->count('Genre'));
	}

	if ($entity eq 'songs') {
		$request->addResult("_$entity", Slim::Schema->rs('Track')->browse->count);
	}
	
	$request->setStatusDone();
}


sub irenableQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['irenable']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_irenable', $client->irenable());
	
	$request->setStatusDone();
}


sub linesperscreenQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['linesperscreen']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();

	$request->addResult('_linesperscreen', $client->linesPerScreen());
	
	$request->setStatusDone();
}


sub mixerQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['mixer'], ['volume', 'muting', 'treble', 'bass', 'pitch']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client = $request->client();
	my $entity = $request->getRequest(1);

	if ($entity eq 'muting') {
		$request->addResult("_$entity", $prefs->client($client)->get("mute"));
	}
	elsif ($entity eq 'volume') {
		$request->addResult("_$entity", $prefs->client($client)->get("volume"));
	} else {
		$request->addResult("_$entity", $client->$entity());
	}
	
	$request->setStatusDone();
}


sub modeQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['mode']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();

	$request->addResult('_mode', Slim::Player::Source::playmode($client));
	
	$request->setStatusDone();
}


sub musicfolderQuery {
	my $request = shift;
	
	$log->info("musicfolderQuery()");

	# check this is the correct query.
	if ($request->isNotQuery([['musicfolder']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $folderId = $request->getParam('folder_id');
	my $url      = $request->getParam('url');
	my $menu     = $request->getParam('menu');
	my $insert   = $request->getParam('menu_all');
	
	# menu/jive mgmt
	my $menuMode  = defined $menu;
	my $insertAll = $menuMode && defined $insert;
	
	# url overrides any folderId
	my $params = ();
	
	if (defined $url) {
		$params->{'url'} = $url;
	} else {
		# findAndScanDirectory sorts it out if $folderId is undef
		$params->{'id'} = $folderId;
	}
	
	# Pull the directory list, which will be used for looping.
	my ($topLevelObj, $items, $count) = Slim::Utils::Misc::findAndScanDirectoryTree($params);

	# create filtered data
	
	my $topPath = $topLevelObj->path;
	my $osName  = Slim::Utils::OSDetect::OS();
	my @data;

	for my $relPath (@$items) {

		$log->debug("relPath: $relPath" );
		
		my $url  = Slim::Utils::Misc::fixPath($relPath, $topPath) || next;

		$log->debug("url: $url" );

		# Amazingly, this just works. :)
		# Do the cheap compare for osName first - so non-windows users
		# won't take the penalty for the lookup.
		if ($osName eq 'win' && Slim::Music::Info::isWinShortcut($url)) {
			$url = Slim::Utils::Misc::fileURLFromWinShortcut($url);
		}
	
		my $item = Slim::Schema->rs('Track')->objectForUrl({
			'url'      => $url,
			'create'   => 1,
			'readTags' => 1,
		});
	
		if (!blessed($item) || !$item->can('content_type')) {

			next;
		}

		# Bug: 1360 - Don't show files referenced in a cuesheet
		next if ($item->content_type eq 'cur');

		push @data, $item;
	}

	$count = scalar(@data);

	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# assume we have a folder, for other types we will override in the item
		# we go to musicfolder from musicfolder :)

		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => ["musicfolder"],
					'params' => {
						menu     => 'musicfolder',
						menu_all => '1',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
				'add-hold' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'insert',
					},
					'itemsParams' => 'params',
				},
			},
			window => {
				titleStyle => 'musicfolder',
			},
		};
		$request->addResult('base', $base);
	}

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	my $totalCount = _fixCount($insertAll, \$index, \$quantity, $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {
		
		my $loopname =  $menuMode?'item_loop':'folder_loop';
		my $chunkCount = 0;
		$request->addResult( 'offset', $request->getParam('_index') ) if $menuMode;
		
		if ($insertAll) {
			$chunkCount = _playAll(start => $start, end => $end, chunkCount => $chunkCount, request => $request, loopname => $loopname);
		}

		for my $eachitem (@data[$start..$end]) {

			next if ($eachitem == undef);

			my $filename = Slim::Music::Info::fileName($eachitem->url());
			my $id = $eachitem->id();
			$id += 0;
			
			if ($menuMode) {
				$request->addResultLoop($loopname, $chunkCount, 'text', $filename);

				my $params = {
					'textkey' => uc(substr($filename, 0, 1)),
				};
				
				# each item is different, but most items are folders
				# the base assumes so above, we override it here
				

				# assumed case, folder
				if (Slim::Music::Info::isDir($eachitem) || -d Slim::Utils::Misc::pathFromMacAlias($eachitem->url)) {

					$params->{'folder_id'} = $id;

				# playlist
				} elsif (Slim::Music::Info::isPlaylist($eachitem)) {
					
					my $actions = {
						'go' => {
							'cmd' => ['playlists', 'tracks'],
							'params' => {
								menu        => 'songinfo',
								menu_all    => '1',
								playlist_id => $id,
							},
						},
						'play' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'load',
								'playlist_id' => $id,
							},
						},
						'add' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'add',
								'playlist_id' => $id,
							},
						},
						'add-hold' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'insert',
								'playlist_id' => $id,
							},
						},
					};
					$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);

				# song
				} elsif (Slim::Music::Info::isSong($eachitem)) {
					
					my $actions = {
						'go' => {
							'cmd' => ['songinfo'],
							'params' => {
								'menu' => 'nowhere',
								'track_id' => $id,
							},
						},
						'play' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'load',
								'track_id' => $id,
							},
						},
						'add' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'add',
								'track_id' => $id,
							},
						},
						'add-hold' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'insert',
								'track_id' => $id,
							},
						},
					};
					$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);

				# not sure
				} else {
					
					# don't know what that is, abort!
					my $actions = {
						'go' => {
							'cmd' => ["musicfolder"],
							'params' => {
								'menu' => 'musicfolder',
							},
							'itemsParams' => 'params',
						},
						'play' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'load',
							},
							'itemsParams' => 'params',
						},
						'add' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'add',
							},
							'itemsParams' => 'params',
						},
						'add-hold' => {
							'player' => 0,
							'cmd' => ['playlistcontrol'],
							'params' => {
								'cmd' => 'insert',
							},
							'itemsParams' => 'params',
						},
					};
					$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
				}

				$request->addResultLoop($loopname, $chunkCount, 'params', $params);
			}

			else {
				$request->addResultLoop($loopname, $chunkCount, 'id', $id);
				$request->addResultLoop($loopname, $chunkCount, 'filename', $filename);
			
				if (Slim::Music::Info::isDir($eachitem)) {
					$request->addResultLoop($loopname, $chunkCount, 'type', 'folder');
				} elsif (Slim::Music::Info::isPlaylist($eachitem)) {
					$request->addResultLoop($loopname, $chunkCount, 'type', 'playlist');
				} elsif (Slim::Music::Info::isSong($eachitem)) {
					$request->addResultLoop($loopname, $chunkCount, 'type', 'track');
				} elsif (-d Slim::Utils::Misc::pathFromMacAlias($eachitem->url)) {
					$request->addResultLoop($loopname, $chunkCount, 'type', 'folder');
				} else {
					$request->addResultLoop($loopname, $chunkCount, 'type', 'unknown');
				}
			}
			$chunkCount++;
		}
	}

	if ($totalCount == 0 && $menuMode) {
		_jiveNoResults($request);
	} else {
		$request->addResult('count', $totalCount);
	}

	# we might have changed - flush to the db to be in sync.
	$topLevelObj->update;
	
	$request->setStatusDone();
}


sub nameQuery {
	my $request = shift;

	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['name']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $client = $request->client();

	$request->addResult("_value", $client->name());
	
	$request->setStatusDone();
}


sub playerXQuery {
	my $request = shift;

	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['player'], ['count', 'name', 'address', 'ip', 'id', 'model', 'displaytype', 'isplayer', 'canpoweroff', 'uuid']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $entity;
	$entity      = $request->getRequest(1);
	# if element 1 is 'player', that means next element is the entity
	$entity      = $request->getRequest(2) if $entity eq 'player';  
	my $clientparam = $request->getParam('_IDorIndex');
	
	if ($entity eq 'count') {
		$request->addResult("_$entity", Slim::Player::Client::clientCount());

	} else {	
		my $client;
		
		# were we passed an ID?
		if (defined $clientparam && Slim::Utils::Misc::validMacAddress($clientparam)) {

			$client = Slim::Player::Client::getClient($clientparam);

		} else {
		
			# otherwise, try for an index
			my @clients = Slim::Player::Client::clients();

			if (defined $clientparam && defined $clients[$clientparam]) {
				$client = $clients[$clientparam];
			}
		}

		# brute force attempt using eg. player's IP address (web clients)
		if (!defined $client) {
			$client = Slim::Player::Client::getClient($clientparam);
		}

		if (defined $client) {

			if ($entity eq "name") {
				$request->addResult("_$entity", $client->name());
			} elsif ($entity eq "address" || $entity eq "id") {
				$request->addResult("_$entity", $client->id());
			} elsif ($entity eq "ip") {
				$request->addResult("_$entity", $client->ipport());
			} elsif ($entity eq "model") {
				$request->addResult("_$entity", $client->model());
			} elsif ($entity eq "isplayer") {
				$request->addResult("_$entity", $client->isPlayer());
			} elsif ($entity eq "displaytype") {
				$request->addResult("_$entity", $client->vfdmodel());
			} elsif ($entity eq "canpoweroff") {
				$request->addResult("_$entity", $client->canPowerOff());
			} elsif ($entity eq "uuid") {
                                $request->addResult("_$entity", $client->uuid());
                        }
		}
	}
	
	$request->setStatusDone();
}

sub playersQuery {
	my $request = shift;

	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['players']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	
	my @prefs;
	
	if (defined(my $pref_list = $request->getParam('playerprefs'))) {

		# split on commas
		@prefs = split(/,/, $pref_list);
	}
	
	my $count = Slim::Player::Client::clientCount();
	$count += 0;

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);
	$request->addResult('count', $count);

	if ($valid) {
		my $idx = $start;
		my $cnt = 0;
		my @players = Slim::Player::Client::clients();

		if (scalar(@players) > 0) {

			for my $eachclient (@players[$start..$end]) {
				$request->addResultLoop('players_loop', $cnt, 
					'playerindex', $idx);
				$request->addResultLoop('players_loop', $cnt, 
					'playerid', $eachclient->id());
                                $request->addResultLoop('players_loop', $cnt,
                                        'uuid', $eachclient->uuid());
				$request->addResultLoop('players_loop', $cnt, 
					'ip', $eachclient->ipport());
				$request->addResultLoop('players_loop', $cnt, 
					'name', $eachclient->name());
				$request->addResultLoop('players_loop', $cnt, 
					'model', $eachclient->model());
				$request->addResultLoop('players_loop', $cnt, 
					'isplayer', $eachclient->isPlayer());
				$request->addResultLoop('players_loop', $cnt, 
					'displaytype', $eachclient->vfdmodel())
					unless ($eachclient->model() eq 'http');
				$request->addResultLoop('players_loop', $cnt, 
					'canpoweroff', $eachclient->canPowerOff());
				$request->addResultLoop('players_loop', $cnt, 
					'connected', ($eachclient->connected() || 0));

				for my $pref (@prefs) {
					if (defined(my $value = $prefs->client($eachclient)->get($pref))) {
						$request->addResultLoop('players_loop', $cnt, 
							$pref, $value);
					}
				}
					
				$idx++;
				$cnt++;
			}	
		}
	}
	
	$request->setStatusDone();
}


sub playlistPlaylistsinfoQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['playlist'], ['playlistsinfo']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	my $playlistObj = $client->currentPlaylist();
	
	if (blessed($playlistObj)) {
		if ($playlistObj->can('id')) {
			$request->addResult("id", $playlistObj->id());
		}

		$request->addResult("name", $playlistObj->title());
				
		$request->addResult("modified", $client->currentPlaylistModified());

		$request->addResult("url", $playlistObj->url());
	}
	
	$request->setStatusDone();
}


sub playlistXQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['playlist'], ['name', 'url', 'modified', 
			'tracks', 'duration', 'artist', 'album', 'title', 'genre', 'path', 
			'repeat', 'shuffle', 'index', 'jump', 'remote']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();
	my $entity = $request->getRequest(1);
	my $index  = $request->getParam('_index');
		
	if ($entity eq 'repeat') {
		$request->addResult("_$entity", Slim::Player::Playlist::repeat($client));

	} elsif ($entity eq 'shuffle') {
		$request->addResult("_$entity", Slim::Player::Playlist::shuffle($client));

	} elsif ($entity eq 'index' || $entity eq 'jump') {
		$request->addResult("_$entity", Slim::Player::Source::playingSongIndex($client));

	} elsif ($entity eq 'name' && defined(my $playlistObj = $client->currentPlaylist())) {
		$request->addResult("_$entity", Slim::Music::Info::standardTitle($client, $playlistObj));

	} elsif ($entity eq 'url') {
		my $result = $client->currentPlaylist();
		$request->addResult("_$entity", $result);

	} elsif ($entity eq 'modified') {
		$request->addResult("_$entity", $client->currentPlaylistModified());

	} elsif ($entity eq 'tracks') {
		$request->addResult("_$entity", Slim::Player::Playlist::count($client));

	} elsif ($entity eq 'path') {
		my $result = Slim::Player::Playlist::url($client, $index);
		$request->addResult("_$entity",  $result || 0);

	} elsif ($entity eq 'remote') {
		if (defined (my $url = Slim::Player::Playlist::url($client, $index))) {
			$request->addResult("_$entity", Slim::Music::Info::isRemoteURL($url));
		}
		
	} elsif ($entity =~ /(duration|artist|album|title|genre)/) {

		my $track = Slim::Schema->rs('Track')->objectForUrl({
			'url'      => Slim::Player::Playlist::song($client, $index),
			'create'   => 1,
			'readTags' => 1,
		});

		if (blessed($track) && $track->can('secs')) {

			# Just call the method on Track
			if ($entity eq 'duration') {

				$request->addResult("_$entity", $track->secs());
			
			} elsif ($entity eq 'album' || $entity eq 'artist' || $entity eq 'genre') {

				$request->addResult("_$entity", $track->$entity->name || 0);

			} else {

				$request->addResult("_$entity", $track->$entity());
			}
		}
	}
	
	$request->setStatusDone();
}


sub playlistsTracksQuery {
	my $request = shift;

	$log->info("Begin Function");

	# check this is the correct query.
	# "playlisttracks" is deprecated (July 06).
	if ($request->isNotQuery([['playlisttracks']]) &&
		$request->isNotQuery([['playlists'], ['tracks']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $tags       = 'gald';
	my $index      = $request->getParam('_index');
	my $quantity   = $request->getParam('_quantity');
	my $tagsprm    = $request->getParam('tags');
	my $playlistID = $request->getParam('playlist_id');

	if (!defined $playlistID) {
		$request->setStatusBadParams();
		return;
	}
	my $menu          = $request->getParam('menu');
	my $insert        = $request->getParam('menu_all');
	
	# menu/jive mgmt
	my $menuMode = defined $menu;
	my $insertAll = $menuMode && defined $insert;
		
	# did we have override on the defaults?
	$tags = $tagsprm if defined $tagsprm;

	my $iterator;
	my @tracks;

	my $playlistObj = Slim::Schema->find('Playlist', $playlistID);

	if (blessed($playlistObj) && $playlistObj->can('tracks')) {
		$iterator = $playlistObj->tracks();
	}

	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to songingo after playlists tracks, so we get menu:songinfo
		# from the artists we'll go to albums

		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => ['songinfo'],
					'params' => {
						'menu' => 'nowhere',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
				'add-hold' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'insert',
					},
					'itemsParams' => 'params',
				},
			},
		};
		$request->addResult('base', $base);
	}

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	if (defined $iterator) {

		my $totalCount = $iterator->count();
		$totalCount += 0;
		
		my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $totalCount);

		if ($valid) {


			my $format = $prefs->get('titleFormat')->[ $prefs->get('titleFormatWeb') ];
			my $cur = $start;
			my $loopname = $menuMode?'item_loop':'playlisttracks_loop';
			my $chunkCount = 0;
			$request->addResult( 'offset', $request->getParam('_index') ) if $menuMode;
			
			if ($insertAll) {
				$chunkCount = _playAll(start => $start, end => $end, chunkCount => $chunkCount, request => $request, loopname => $loopname);
			}

			for my $eachitem ($iterator->slice($start, $end)) {

				if ($menuMode) {
					
					my $text = Slim::Music::TitleFormatter::infoFormat($eachitem, $format, 'TITLE');
					$request->addResultLoop($loopname, $chunkCount, 'text', $text);
					my $id = $eachitem->id();
					$id += 0;
					my $params = {
						'track_id' =>  $id, 
					};
					$request->addResultLoop($loopname, $chunkCount, 'params', $params);

				}
				else {
					_addSong($request, $loopname, $chunkCount, $eachitem, $tags, 
							"playlist index", $cur);
				}
				
				$cur++;
				$chunkCount++;
			}


			my $lastChunk;
			if ( $end == $totalCount - 1 && $chunkCount < $request->getParam('_quantity') ) {
				$lastChunk = 1;
			}

                        # add a favorites link below play/add links
                        #Add another to result count
                        my %favorites;
                        $favorites{'title'} = $playlistObj->name;
                        $favorites{'url'} = $playlistObj->url;

			($chunkCount, $totalCount) = _jiveDeletePlaylist(start => $start, end => $end, lastChunk => $lastChunk, listCount => $totalCount, chunkCount => $chunkCount, request => $request, loopname => $loopname, playlistURL => $playlistObj->url, playlistID => $playlistID, playlistTitle => $playlistObj->name );
			($chunkCount, $totalCount) = _jiveAddToFavorites(lastChunk => $lastChunk, start => $start, chunkCount => $chunkCount, listCount => $totalCount, request => $request, loopname => $loopname, favorites => \%favorites);

		}
		$request->addResult("count", $totalCount);

	} else {

		$request->addResult("count", 0);
	}

	$request->setStatusDone();	
}


sub playlistsQuery {
	my $request = shift;

	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['playlists']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $search   = $request->getParam('search');
	my $tags     = $request->getParam('tags') || '';
	my $menu     = $request->getParam('menu');
	my $insert   = $request->getParam('menu_all');
	
	# menu/jive mgmt
	my $menuMode  = defined $menu;
	my $insertAll = $menuMode && defined $insert;

	# Normalize any search parameters
	if (defined $search) {
		$search = Slim::Utils::Text::searchStringSplit($search);
	}

	my $rs = Slim::Schema->rs('Playlist')->getPlaylists('all', $search);

	# now build the result
	my $count = $rs->count;
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to playlists tracks after playlists, so we get menu:track
		# from the tracks we'll go to songinfo
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => ['playlists', 'tracks'],
					'params' => {
						menu     => 'songinfo',
						menu_all => '1',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
				'add-hold' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'insert',
					},
					'itemsParams' => 'params',
				},
			},
			window => {
				titleStyle => 'playlist',
			},
		};
		$request->addResult('base', $base);
	}

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	if (defined $rs) {

		$count += 0;
		my $totalCount = _fixCount($insertAll, \$index, \$quantity, $count);
		
		my ($valid, $start, $end) = $request->normalize(
			scalar($index), scalar($quantity), $count);

		if ($valid) {
			
			my $loopname = $menuMode?'item_loop':'playlists_loop';
			my $chunkCount = 0;
			$request->addResult( 'offset', $request->getParam('_index') ) if $menuMode;

			if ($insertAll) {
				$chunkCount = _playAll(start => $start, end => $end, chunkCount => $chunkCount, request => $request, loopname => $loopname);
			}

			for my $eachitem ($rs->slice($start, $end)) {

				my $id = $eachitem->id();
				$id += 0;

				if ($menuMode) {
					$request->addResultLoop($loopname, $chunkCount, 'text', $eachitem->title);

					my $params = {
						'playlist_id' =>  $id, 
						'textkey' => substr($eachitem->namesort, 0, 1),
					};

					$request->addResultLoop($loopname, $chunkCount, 'params', $params);
				} else {
					$request->addResultLoop($loopname, $chunkCount, "id", $id);
					$request->addResultLoop($loopname, $chunkCount, "playlist", $eachitem->title);
					$request->addResultLoop($loopname, $chunkCount, "url", $eachitem->url) if ($tags =~ /u/);
				}
				$chunkCount++;
			}
		}
		if ($totalCount == 0 && $menuMode) {
			_jiveNoResults($request);
		} else {
			$request->addResult("count", $totalCount);
		}
	} else {
		$request->addResult("count", 0);
	}

	$request->setStatusDone();
}


sub playerprefQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['playerpref']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client   = $request->client();
	my $prefName = $request->getParam('_prefname');

	# split pref name from namespace: name.space.pref:
	my $namespace = 'server';
	if ($prefName =~ /^(.*):(\w+)$/) {
		$namespace = $1;
		$prefName = $2;
	}
	
	if (!defined $prefName || !defined $namespace) {
		$request->setStatusBadParams();
		return;
	}

	$request->addResult('_p2', preferences($namespace)->client($client)->get($prefName));
	
	$request->setStatusDone();
}


sub playerprefValidateQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['playerpref'], ['validate']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $client   = $request->client();
	my $prefName = $request->getParam('_prefname');
	my $newValue = $request->getParam('_newvalue');

	# split pref name from namespace: name.space.pref:
	my $namespace = 'server';
	if ($prefName =~ /^(.*):(\w+)$/) {
		$namespace = $1;
		$prefName = $2;
	}
	
	if (!defined $prefName || !defined $namespace || !defined $newValue) {
		$request->setStatusBadParams();
		return;
	}

	$request->addResult('valid', preferences($namespace)->client($client)->validate($prefName, $newValue) ? 1 : 0);
	
	$request->setStatusDone();
}


sub powerQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['power']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_power', $client->power());
	
	$request->setStatusDone();
}


sub prefQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['pref']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $prefName = $request->getParam('_prefname');

	# split pref name from namespace: name.space.pref:
	my $namespace = 'server';
	if ($prefName =~ /^(.*):(\w+)$/) {
		$namespace = $1;
		$prefName = $2;
	}
	
	if (!defined $prefName || !defined $namespace) {
		$request->setStatusBadParams();
		return;
	}

	$request->addResult('_p2', preferences($namespace)->get($prefName));
	
	$request->setStatusDone();
}


sub prefValidateQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['pref'], ['validate']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $prefName = $request->getParam('_prefname');
	my $newValue = $request->getParam('_newvalue');

	# split pref name from namespace: name.space.pref:
	my $namespace = 'server';
	if ($prefName =~ /^(.*):(\w+)$/) {
		$namespace = $1;
		$prefName = $2;
	}
	
	if (!defined $prefName || !defined $namespace || !defined $newValue) {
		$request->setStatusBadParams();
		return;
	}

	$request->addResult('valid', preferences($namespace)->validate($prefName, $newValue) ? 1 : 0);
	
	$request->setStatusDone();
}


sub rateQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['rate']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_rate', Slim::Player::Source::rate($client));
	
	$request->setStatusDone();
}


sub readDirectoryQuery {
	my $request = shift;

	$log->info("readDirectoryQuery");

	# check this is the correct query.
	if ($request->isNotQuery([['readdirectory']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $folder   = Slim::Utils::Unicode::utf8off($request->getParam('folder'));
	my $filter   = $request->getParam('filter');

	use File::Spec::Functions qw(catdir);
	my @fsitems;		# raw list of items 
	my %fsitems;		# meta data cache

	if ($folder eq '/' && Slim::Utils::OSDetect::OS() eq 'win') {
		@fsitems = sort map {
			$fsitems{"$_:"} = {
				d => 1,
				f => 0
			};
			"$_:"; 
		} Win32::DriveInfo::DrivesInUse();
		$folder = '';
	}
	else {
		$filter ||= '';

		my $filterRE = qr/./ unless ($filter eq 'musicfiles');

		# get file system items in $folder
		@fsitems = Slim::Utils::Misc::readDirectory(catdir($folder), $filterRE);
		map { 
			$fsitems{$_} = {
				d => -d catdir($folder, $_),
				f => -f _
			}
		} @fsitems;
	}

	if ($filter eq 'foldersonly') {
		@fsitems = grep { $fsitems{$_}->{d} } @fsitems;
	}

	elsif ($filter eq 'filesonly') {
		@fsitems = grep { $fsitems{$_}->{f} } @fsitems;
	}

	# return all folders plus files of type
	elsif ($filter =~ /^filetype:(.*)/) {
		my $filterRE = qr/\.$1$/;
		@fsitems = grep { $fsitems{$_}->{d} || $_ =~ $filterRE } @fsitems;
	}

	# search anywhere within path/filename
	elsif ($filter && $filter !~ /^(?:filename|filetype):/) {
		@fsitems = grep { catdir($folder, $_) =~ /$filter/i } @fsitems;
	}

	my $count = @fsitems;
	$count += 0;
	$request->addResult('count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {
		my $idx = $start;
		my $cnt = 0;

		if (scalar(@fsitems)) {
			# sort folders < files
			@fsitems = sort { 
				if ($fsitems{$a}->{d}) {
					if ($fsitems{$b}->{d}) { uc($a) cmp uc($b) }
					else { -1 }
				}
				else {
					if ($fsitems{$b}->{d}) { 1 }
					else { uc($a) cmp uc($b) }
				}
			} @fsitems;

			my $path;
			for my $item (@fsitems[$start..$end]) {
				$path = ($folder ? catdir($folder, $item) : $item);

				$request->addResultLoop('fsitems_loop', $cnt, 'path', Slim::Utils::Unicode::utf8decode($path));
				$request->addResultLoop('fsitems_loop', $cnt, 'name', Slim::Utils::Unicode::utf8decode($item));
				$request->addResultLoop('fsitems_loop', $cnt, 'isfolder', $fsitems{$item}->{d});

				$idx++;
				$cnt++;
			}	
		}
	}

	$request->setStatusDone();	
}


sub rescanQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['rescan']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# no params for the rescan query

	$request->addResult('_rescan', Slim::Music::Import->stillScanning() ? 1 : 0);
	
	$request->setStatusDone();
}


sub rescanprogressQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['rescanprogress']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# no params for the rescanprogress query

	if (Slim::Music::Import->stillScanning) {
		$request->addResult('rescan', 1);

		# get progress from DB
		my $args = {
			'type' => 'importer',
		};

		my @progress = Slim::Schema->rs('Progress')->search( $args, { 'order_by' => 'start,id' } )->all;

		# calculate total elapsed time
		my $total_time = 0;
		for my $p (@progress) {
			my $runtime = ($p->finish || time()) - $p->start;
			$total_time += $runtime;
		}

		# report it
		my $hrs  = int($total_time / 3600);
		my $mins = int(($total_time - $hrs * 60)/60);
		my $sec  = $total_time - 3600 * $hrs - 60 * $mins;
		$request->addResult('totaltime', sprintf("%02d:%02d:%02d", $hrs, $mins, $sec));

		# now indicate % completion for all importers
		for my $p (@progress) {

			my $percComplete = $p->finish ? 100 : $p->total ? $p->done / $p->total * 100 : -1;
			$request->addResult($p->name(), int($percComplete));
		}
	
	# if we're not scanning, just say so...
	} else {
		$request->addResult('rescan', 0);
	}

	$request->setStatusDone();
}


sub searchQuery {
	my $request = shift;

	$log->info("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['search']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $query    = $request->getParam('term');

	if (!defined $query || $query eq '') {
		$request->setStatusBadParams();
		return;
	}

	if (Slim::Music::Import->stillScanning) {
		$request->addResult('rescan', 1);
	}

	my $totalCount = 0;
	my $search     = Slim::Utils::Text::searchStringSplit($query);
	my %results    = ();
	my @types      = Slim::Schema->searchTypes;

	# Ugh - we need two loops here, as "count" needs to come first.
	for my $type (@types) {

		my $rs      = Slim::Schema->rs($type)->searchNames($search);
		my $count   = $rs->count || 0;

		$results{$type}->{'rs'}    = $rs;
		$results{$type}->{'count'} = $count;

		$totalCount += $count;
	}

	$totalCount += 0;
	$request->addResult('count', $totalCount);

	for my $type (@types) {

		my $count = $results{$type}->{'count'};

		$count += 0;

		my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

		if ($valid) {
			$request->addResult("${type}s_count", $count);
	
			my $loopName  = "${type}s_loop";
			my $loopCount = 0;
	
			for my $result ($results{$type}->{'rs'}->slice($start, $end)) {
	
				# add result to loop
				$request->addResultLoop($loopName, $loopCount, "${type}_id", $result->id);
				$request->addResultLoop($loopName, $loopCount, $type, $result->name);
	
				$loopCount++;
			}
		}
	}
	
	$request->setStatusDone();
}


# the filter function decides, based on a notified request, if the serverstatus
# query must be re-executed.
sub serverstatusQuery_filter {
	my $self = shift;
	my $request = shift;
	
	# we want to know about rescan and all client notifs, as well as power on/off
	# FIXME: wipecache and rescan are synonyms...
	if ($request->isCommand([['wipecache', 'rescan', 'client', 'power']])) {
		return 1.3;
	}
	
	# FIXME: prefset???
	# we want to know about any pref in our array
	if (defined(my $prefsPtr = $self->privateData()->{'server'})) {
		if ($request->isCommand([['pref']])) {
			if (defined(my $reqpref = $request->getParam('_prefname'))) {
				if (grep($reqpref, @{$prefsPtr})) {
					return 1.3;
				}
			}
		}
	}
	if (defined(my $prefsPtr = $self->privateData()->{'player'})) {
		if ($request->isCommand([['playerpref']])) {
			if (defined(my $reqpref = $request->getParam('_prefname'))) {
				if (grep($reqpref, @{$prefsPtr})) {
					return 1.3;
				}
			}
		}
	}
	if ($request->isCommand([['name']])) {
		return 1.3;
	}
	
	return 0;
}


sub serverstatusQuery {
	my $request = shift;
	
	$log->info("serverstatusQuery()");

	# check this is the correct query
	if ($request->isNotQuery([['serverstatus']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', "1");
		if (my $p = Slim::Schema->rs('Progress')->search({ 'type' => 'importer', 'active' => 1 })->first) {

			$request->addResult('progressname', Slim::Utils::Strings::string($p->name."_PROGRESS"));
			$request->addResult('progressdone', $p->done);
			$request->addResult('progresstotal', $p->total);
		}
	}
	
	# add version
	$request->addResult('version', $::VERSION);

	# add totals
	$request->addResult("info total albums", Slim::Schema->count('Album'));
	$request->addResult("info total artists", Slim::Schema->rs('Contributor')->browse->count);
	$request->addResult("info total genres", Slim::Schema->count('Genre'));
	$request->addResult("info total songs", Slim::Schema->rs('Track')->browse->count);

	my %savePrefs;
	if (defined(my $pref_list = $request->getParam('prefs'))) {

		# split on commas
		my @prefs = split(/,/, $pref_list);
		$savePrefs{'server'} = \@prefs;
	
		for my $pref (@{$savePrefs{'server'}}) {
			if (defined(my $value = $prefs->get($pref))) {
				$request->addResult($pref, $value);
			}
		}
	}
	if (defined(my $pref_list = $request->getParam('playerprefs'))) {

		# split on commas
		my @prefs = split(/,/, $pref_list);
		$savePrefs{'player'} = \@prefs;
		
	}


	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');

	my $count = Slim::Player::Client::clientCount();
	$count += 0;

	$request->addResult('player count', $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $cnt = 0;
		my @players = Slim::Player::Client::clients();

		if (scalar(@players) > 0) {

			for my $eachclient (@players[$start..$end]) {
				$request->addResultLoop('players_loop', $cnt, 
					'playerid', $eachclient->id());
                                $request->addResultLoop('players_loop', $cnt,
                                        'uuid', $eachclient->uuid());
				$request->addResultLoop('players_loop', $cnt, 
					'ip', $eachclient->ipport());
				$request->addResultLoop('players_loop', $cnt, 
					'name', $eachclient->name());
				$request->addResultLoop('players_loop', $cnt, 
					'model', $eachclient->model());
				$request->addResultLoop('players_loop', $cnt, 
					'power', $eachclient->power());
				$request->addResultLoop('players_loop', $cnt, 
					'displaytype', $eachclient->vfdmodel())
					unless ($eachclient->model() eq 'http');
				$request->addResultLoop('players_loop', $cnt, 
					'canpoweroff', $eachclient->canPowerOff());
				$request->addResultLoop('players_loop', $cnt, 
					'connected', ($eachclient->connected() || 0));
				$request->addResultLoop('players_loop', $cnt, 
					'isplayer', ($eachclient->isPlayer() || 0));
				$request->addResultLoop('players_loop', $cnt, 
					'player_needs_upgrade', "1")
					if ($eachclient->needsUpgrade());
				$request->addResultLoop('players_loop', $cnt,
					'player_is_upgrading', "1")
					if ($eachclient->isUpgrading());

				for my $pref (@{$savePrefs{'player'}}) {
					if (defined(my $value = $prefs->client($eachclient)->get($pref))) {
						$request->addResultLoop('players_loop', $cnt, 
							$pref, $value);
					}
				}
					
				$cnt++;
			}
		}

	}


	my @sn_players = Slim::Networking::SqueezeNetwork::Players->get_players();

	$count = scalar @sn_players || 0;

	$request->addResult('sn player count', $count);

	($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $sn_cnt = 0;
			
		for my $player ( @sn_players ) {
			$request->addResultLoop(
				'sn_players_loop', $sn_cnt, 'id', $player->{id}
			);
			
			$request->addResultLoop( 
				'sn_players_loop', $sn_cnt, 'name', $player->{name}
			);
			
			$request->addResultLoop(
				'sn_players_loop', $sn_cnt, 'playerid', $player->{mac}
			);
				
			$sn_cnt++;
		}
	}
	
	# manage the subscription
	if (defined(my $timeout = $request->getParam('subscribe'))) {
	
		# store the prefs array as private data so our filter above can find it back
		$request->privateData(\%savePrefs);
		
		# register ourselves to be automatically re-executed on timeout or filter
		$request->registerAutoExecute($timeout, \&serverstatusQuery_filter);
	}
	
	$request->setStatusDone();
}


sub signalstrengthQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['signalstrength']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_signalstrength', $client->signalStrength() || 0);
	
	$request->setStatusDone();
}


sub sleepQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['sleep']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	my $isValue = $client->sleepTime() - Time::HiRes::time();
	if ($isValue < 0) {
		$isValue = 0;
	}
	
	$request->addResult('_sleep', $isValue);
	
	$request->setStatusDone();
}


# the filter function decides, based on a notified request, if the status
# query must be re-executed.
sub statusQuery_filter {
	my $self = shift;
	my $request = shift;
	
	# retrieve the clientid, abort if not about us
	my $clientid = $request->clientid();
	return 0 if !defined $clientid;
	return 0 if $clientid ne $self->clientid();
	
	# commands we ignore
	return 0 if $request->isCommand([['ir', 'button', 'debug', 'pref', 'display', 'prefset', 'playerpref']]);
	return 0 if $request->isCommand([['playlist'], ['open', 'jump']]);

	# special case: the client is gone!
	if ($request->isCommand([['client'], ['forget']])) {
		
		# pretend we do not need a client, otherwise execute() fails
		# and validate() deletes the client info!
		$self->needClient(0);
		
		# we'll unsubscribe above if there is no client
		return 1;
	}

	# suppress frequent updates during volume changes
	if ($request->isCommand([['mixer'], ['volume']])) {

		return 3;
	}

	# give it a tad more time for muting to leave room for the fade to finish
	# see bug 5255
	if ($request->isCommand([['mixer'], ['muting']])) {

		return 1.4;
	}

	# send everyother notif with a small delay to accomodate
	# bursts of commands
	return 1.3;
}


sub statusQuery {
	my $request = shift;
	
	$log->info("statusQuery()");

	# check this is the correct query
	if ($request->isNotQuery([['status']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the initial parameters
	my $client = $request->client();
	my $menu = $request->getParam('menu');
	
	# menu/jive mgmt
	my $menuMode = defined $menu;

	# accomodate the fact we can be called automatically when the client is gone
	if (!defined($client)) {
		$request->addResult('error', "invalid player");
		$request->registerAutoExecute('-');
		$request->setStatusDone();
		return;
	}
		
	my $SP3  = ($client->model() eq 'slimp3');
	my $SQ   = ($client->model() eq 'softsqueeze');
	my $SB   = ($client->model() eq 'squeezebox');
	my $SB2  = ($client->model() eq 'squeezebox2');
	my $TS   = ($client->model() eq 'transporter');
	my $RSC  = ($client->model() eq 'http');
	
	my $connected = $client->connected() || 0;
	my $power     = $client->power();
	my $repeat    = Slim::Player::Playlist::repeat($client);
	my $shuffle   = Slim::Player::Playlist::shuffle($client);
	my $songCount = Slim::Player::Playlist::count($client);
	my $idx = 0;


	# now add the data...

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', "1");
	}

	if ($client->needsUpgrade()) {
		$request->addResult('player_needs_upgrade', "1");
	}
	
	if ($client->isUpgrading()) {
		$request->addResult('player_is_upgrading', "1");
	}
	
	# add player info...
	$request->addResult("player_name", $client->name());
	$request->addResult("player_connected", $connected);

	# add showBriefly info
	if ($client->display->renderCache->{showBriefly}
		&& $client->display->renderCache->{showBriefly}->{line}
		&& $client->display->renderCache->{showBriefly}->{ttl} > time()) {
		$request->addResult('showBriefly', $client->display->renderCache->{showBriefly}->{line});
	}

	if (!$RSC) {
		$power += 0;
		$request->addResult("power", $power);
	}
	
	if ($SB || $SB2 || $TS) {
		$request->addResult("signalstrength", ($client->signalStrength() || 0));
	}
	
	my $playlist_cur_index;
	# this will be true for http class players
	
		$request->addResult('mode', Slim::Player::Source::playmode($client));

		if (my $song = Slim::Player::Playlist::url($client)) {

			if (Slim::Music::Info::isRemoteURL($song)) {
				$request->addResult('remote', 1);
				$request->addResult('current_title', 
					Slim::Music::Info::getCurrentTitle($client, $song));
			}
			
			$request->addResult('time', 
				Slim::Player::Source::songTime($client));
			$request->addResult('rate', 
				Slim::Player::Source::rate($client));
			
			my $track = Slim::Schema->rs('Track')->objectForUrl($song);

			if (blessed($track) && $track->can('secs')) {

				my $dur = $track->secs;

				if ($dur) {
					$dur += 0;
					$request->addResult('duration', $dur);
				}
			}
			
			my $canSeek = Slim::Music::Info::canSeek($client, $song);
			if ($canSeek) {
				$request->addResult('can_seek', 1);
			}
		}
		
		if ($client->currentSleepTime()) {

			my $sleep = $client->sleepTime() - Time::HiRes::time();
			$request->addResult('sleep', $client->currentSleepTime() * 60);
			$request->addResult('will_sleep_in', ($sleep < 0 ? 0 : $sleep));
		}
		
		if (Slim::Player::Sync::isSynced($client)) {

			my $master = Slim::Player::Sync::masterOrSelf($client);

			$request->addResult('sync_master', $master->id());

			my @slaves = Slim::Player::Sync::slaves($master);
			my @sync_slaves = map { $_->id } @slaves;

			$request->addResult('sync_slaves', join(",", @sync_slaves));
		}
	
		if (!$RSC) {
			# undefined for remote streams
			my $vol = $prefs->client($client)->get('volume');
			$vol += 0;
			$request->addResult("mixer volume", $vol);
		}
		
		if ($SB || $SP3) {
			$request->addResult("mixer treble", $client->treble());
			$request->addResult("mixer bass", $client->bass());
		}

		if ($SB) {
			$request->addResult("mixer pitch", $client->pitch());
		}

		$repeat += 0;
		$request->addResult("playlist repeat", $repeat);
		$shuffle += 0;
		$request->addResult("playlist shuffle", $shuffle); 
	
		if (defined (my $playlistObj = $client->currentPlaylist())) {
			$request->addResult("playlist_id", $playlistObj->id());
			$request->addResult("playlist_name", $playlistObj->title());
			$request->addResult("playlist_modified", $client->currentPlaylistModified());
		}

		if ($songCount > 0) {
			$playlist_cur_index = Slim::Player::Source::playingSongIndex($client);
			$request->addResult(
				"playlist_cur_index", 
				$playlist_cur_index
			);
			$request->addResult("playlist_timestamp", $client->currentPlaylistUpdateTime())
		}

		$request->addResult("playlist_tracks", $songCount);
	
	# give a count in menu mode no matter what
	if ($menuMode) {
		$log->debug("statusQuery(): setup base for jive");
		$songCount += 0;
		# add two for playlist save/clear to the count if the playlist is non-empty
		my $menuCount = $songCount?$songCount+2:0;
		$request->addResult("count", $menuCount);
		
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => ['songinfo'],
					'params' => {
						'menu' => 'nowhere', 
						'context' => 'playlist',
					},
					'itemsParams' => 'params',
				},
			},
			'window' => {
				'titleStyle' => 'album',
			}
		};
		$request->addResult('base', $base);
	}
	
	if ($songCount > 0) {
	
		$log->debug("statusQuery(): setup non-zero player response");
		# get the other parameters
		my $tags     = $request->getParam('tags');
		my $index    = $request->getParam('_index');
		my $quantity = $request->getParam('_quantity');
	
		$tags = 'gald' if !defined $tags;
		my $loop = $menuMode ? 'item_loop' : 'playlist_loop';

		# we can return playlist data.
		# which mode are we in?
		my $modecurrent = 0;

		if (defined($index) && ($index eq "-")) {
			$modecurrent = 1;
		}
		
		# if repeat is 1 (song) and modecurrent, then show the current song
		if ($modecurrent && ($repeat == 1) && $quantity) {

			$request->addResult('offset', $playlist_cur_index) if $menuMode;
			my $track = Slim::Player::Playlist::song($client, $playlist_cur_index);

			if ($menuMode) {
				_addJiveSong($request, $loop, 0, 1, $track);
			}
			else {
				_addSong($request, $loop, 0, 
					$track, $tags,
					'playlist index', $playlist_cur_index
				);
			}
			
		} else {

			my ($valid, $start, $end);
			
			if ($modecurrent) {
				($valid, $start, $end) = $request->normalize($playlist_cur_index, scalar($quantity), $songCount);
			} else {
				($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $songCount);
			}

			if ($valid) {
				my $count = 0;
				$start += 0;
				$request->addResult('offset', $request->getParam('_index')) if $menuMode;
				
				for ($idx = $start; $idx <= $end; $idx++) {
					
					my $track = Slim::Player::Playlist::song($client, $idx);
					my $current = ($idx == $playlist_cur_index);

					if ($menuMode) {
						_addJiveSong($request, $loop, $count, $current, $track);
						# add clear and save playlist items at the bottom
						if ( ($idx+1)  == $songCount) {
							_addJivePlaylistControls($request, $loop, $count);
						}
					}
					else {
						_addSong(	$request, $loop, $count, 
									$track, $tags,
									'playlist index', $idx
								);
					}

					$count++;
					
					# give peace a chance...
					if ($count % 5) {
						::idleStreams();
					}
				}
				
				#we don't do that in menu mode!
				if (!$menuMode) {
				
					my $repShuffle = $prefs->get('reshuffleOnRepeat');
					my $canPredictFuture = ($repeat == 2)  			# we're repeating all
											&& 						# and
											(	($shuffle == 0)		# either we're not shuffling
												||					# or
												(!$repShuffle));	# we don't reshuffle
				
					if ($modecurrent && $canPredictFuture && ($count < scalar($quantity))) {

						# wrap around the playlist...
						($valid, $start, $end) = $request->normalize(0, (scalar($quantity) - $count), $songCount);		

						if ($valid) {

							for ($idx = $start; $idx <= $end; $idx++){

								_addSong($request, $loop, $count, 
									Slim::Player::Playlist::song($client, $idx), $tags,
									'playlist index', $idx
								);

								$count++;
								::idleStreams() ;
							}
						}
					}

				}
			}
		}
	}


	# manage the subscription
	if (defined(my $timeout = $request->getParam('subscribe'))) {
		$log->debug("statusQuery(): setting up subscription");
	
		# register ourselves to be automatically re-executed on timeout or filter
		$request->registerAutoExecute($timeout, \&statusQuery_filter);
	}
	
	$request->setStatusDone();
}

sub songinfoQuery {
	my $request = shift;

	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['songinfo']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $tags  = 'abcdefghijJklmnopqrstvwxyzBCDEFHIJKLMNOQRTUVWXYZ'; # all letter EXCEPT u, A & S, G & P
	my $track;

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity');
	my $url	     = $request->getParam('url');
	my $trackID  = $request->getParam('track_id');
	my $tagsprm  = $request->getParam('tags');
	
	my $menu     = $request->getParam('menu');
	my $context  = $request->getParam('context');
	my $playlist_index = $request->getParam('playlist_index');
	my $insert   = $request->getParam('menu_play');

	# menu/jive mgmt
	my $menuMode = defined $menu;
	my $insertPlay = $menuMode;

	if (!defined $trackID && !defined $url) {
		$request->setStatusBadParams();
		return;
	}

	# did we have override on the defaults?
	$tags = $tagsprm if defined $tagsprm;

	# find the track
	if (defined $trackID){

		$track = Slim::Schema->find('Track', $trackID);

	} else {

		if ( defined $url )){

			$track = Slim::Schema->rs('Track')->objectForUrl($url);
		}
	}
	
	# now build the result
	
	if (Slim::Music::Import->stillScanning()) {
		$request->addResult("rescan", 1);
	}

	if (blessed($track) && $track->can('id')) {

		my $trackId = $track->id();
		$trackId += 0;

		if ($menuMode) {

			# decide what is the next step down
			# generally, we go nowhere after songinfo, so we get menu:nowhere...

			# build the base element
			my $go_action;
			if ($menu eq 'nowplaying') {
				$go_action = 
					{ 
						cmd  => ['songinfo'],
						params => {
							menu => 'nowhere',
							itemsParams => 'params', 
							cmd => 'load',
							track_id => $trackId,
					},
				};
			} 
			my $base = {
				actions => {

					# no go, we ain't going anywhere!

					# we play/add the current track id
					play => {
						player => 0,
						cmd => ['playlistcontrol'],
						params => {
							cmd => 'load',
							track_id => $trackId,
						},
					},
					add => {
						player => 0,
						cmd => ['playlistcontrol'],
						params => {
							cmd => 'add',
							track_id => $trackId,
						},
					},
					'add-hold' => {
						player => 0,
						cmd => ['playlistcontrol'],
						params => {
							cmd => 'insert',
							track_id => $trackId,
						},
					},
				},
				window => {
				},
			};
			if ($menu eq 'nowplaying') {
				# this will get album and artist. may need more tags here
				$tags = 'Al'; 
				# actions for next step--drilling down to songinfo
				$base->{'actions'}{'go'} = $go_action;
				$base->{'window'}{'titleStyle'} = 'album';
				$base->{'window'}{'icon-id'} = $trackId;
				$log->error($base->{'actions'}{'go'});
			} else {
				# tags for songinfo page, ordered like SC7 Web UI
				# j tag is '1' if artwork exists; it's put in front so it can act as a flag for "J"
				# J tag gives icon-id for artwork
				$tags = 'jAlGyJkitodYfrTvun';
			}
			$request->addResult('base', $base);
		}

		my $hashRef = _songData($request, $track, $tags, $menuMode);
		my $count = scalar (keys %{$hashRef});

		$count += 0;

		# insertPlay will add Play & Add items - have to fix by two elements
		# first for Play
		my $totalCount = _fixCount($insertPlay, \$index, \$quantity, $count);
		# then for Add (note we are now sending the amended $totalCount to _fixCount()
		$totalCount = _fixCount($insertPlay, \$index, \$quantity, $totalCount);

		my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

		my $loopname = $menuMode?'item_loop':'songinfo_loop';
		$request->addResult('offset', $request->getParam('_index')) if $menuMode;
		my $chunkCount = 0;

		if ($valid) {

		# this is where we construct the nowplaying menu
		if ($menu eq 'nowplaying' && $menuMode) {
			$request->addResult("count", 1);
			$request->addResult('offset', $request->getParam('_index')) if $menuMode;
			my @vals;
			my $loopname = 'item_loop';
			while (my ($key, $val) = each %{$hashRef}) {
				# catch multi-genres or artists
				if ($key =~ /(\w+)::(\d+)/) {
					$key = $1;
					my $id = $val->[0] + 0;
					$val = $val->[1];
				}
				push @vals, $val;
			}
			my $string = join ("\n", @vals);
			$request->addResultLoop($loopname, $chunkCount, 'text', $string);
			$request->addResultLoop($loopname, $chunkCount, 'icon-id', $trackId);
		} else {
			

			my $idx = 0;

			# add Play this song and Add this song items
			if ($insertPlay) {
			
				# insert first item if needed
				if ($start == 0  ) {
					my ($play_string, $add_string, $delete_string, $jump_string);
					if ( $track->remote ) {
						$play_string = Slim::Utils::Strings::string('PLAY');
						$add_string = Slim::Utils::Strings::string('ADD');
						$delete_string = Slim::Utils::Strings::string('REMOVE_FROM_PLAYLIST');
						$jump_string = Slim::Utils::Strings::string('PLAY');
					} else {
						$play_string = Slim::Utils::Strings::string('JIVE_PLAY_THIS_SONG');
						$add_string = Slim::Utils::Strings::string('JIVE_ADD_THIS_SONG');
						$delete_string = Slim::Utils::Strings::string('REMOVE_FROM_PLAYLIST');
						$jump_string = Slim::Utils::Strings::string('JIVE_PLAY_THIS_SONG');
					}	
					# setup hash for different items between play and add
					my %items = ( 	
						'play' => {
							'string'  => $play_string,
							'style'   => 'itemplay',
							'command' => [ 'playlistcontrol' ],
							'cmd'     => 'load',
						},
						'add' => {
							'string'  => $add_string,
							'style'   => 'itemadd',
							'command' => [ 'playlistcontrol' ],
							'cmd'     => 'add',
						},
						'add-hold' => {
							'string'  => $add_string,
							'style'   => 'itemadd',
							'command' => [ 'playlistcontrol' ],
							'cmd'     => 'insert',
						},
						'delete' => {
							'string'  => $delete_string,
							'style'   => 'item',
							'command' => [ 'playlist', 'delete', $playlist_index ],
						},
						'jump' => {
							'string'  => $jump_string,
							'style'   => 'itemplay',
							'command' => [ 'playlist', 'jump', $playlist_index ],
						},

					);
					my $addOrDelete = 'add';
					my $jumpOrPlay = 'play';
					if ( $context eq 'playlist' ) {
						$addOrDelete = 'delete';
						$jumpOrPlay = 'jump';
					}
					for my $mode ($jumpOrPlay, $addOrDelete) {
						# override the actions, babe!
						my $actions = {
							'do' => {
								'player' => 0,
								'cmd' => $items{$mode}{'command'},
							},
							'play' => {
								'player' => 0,
								'cmd' => $items{$mode}{'command'},
							},
							'add' => {
								'player' => 0,
								'cmd'    => $items{'add'}{'command'},
							},
						};
						# tagged params are sent for play and add, not delete/jump
						if ($mode ne 'delete' && $mode ne 'jump') {
							$actions->{'add-hold'} = {
								'player' => 0,
								'cmd' => $items{'add-hold'}{'command'},
							};
							$actions->{'add'}{'params'} = {
									'cmd' => $items{'add'}{'cmd'},
									'track_id' => $trackId,
							};
							$actions->{'add-hold'}{'params'} = {
									'cmd' => $items{'add-hold'}{'cmd'},
									'track_id' => $trackId,
							};
							$actions->{'do'}{'params'} = {
									'cmd' => $items{$mode}{'cmd'},
									'track_id' => $trackId,
							};
							$actions->{'play'}{'params'} = {
									'cmd' => $items{$mode}{'cmd'},
									'track_id' => $trackId,
							};
						
						} else {
							$request->addResultLoop($loopname, $chunkCount, 'nextWindow', 'playlist');
						}
						$request->addResultLoop($loopname, $chunkCount, 'text', $items{$mode}{'string'});
						$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
						$request->addResultLoop($loopname, $chunkCount, 'style', $items{$mode}{'style'});
						$chunkCount++;
					}
				}
			}

			my $artworkExists = 0; # artwork defaults to not being present

			# add a favorites link below play/add links
			#Add another to result count
			my %favorites;
			$favorites{'title'} = $hashRef->{'TITLE'};
			$favorites{'url'}   = $hashRef->{'LOCATION'};
			
			while (my ($key, $val) = each %{$hashRef}) {
				if ( $key eq 'SHOW_ARTWORK' && $val ne '0' ) {
					$artworkExists++; # flag that artwork exists
				}

				my $suppress = 0;
				if ($idx >= $start && $idx <= $end) {

					if ($menuMode) {

						# catch multi-genres or artists
						my $actions;
						if ($key =~ /(\w+)::(\d+)/) {
						
							$key = $1;
							my $id = $val->[0] + 0;
							$val = $val->[1];
							
							# genre
							if ($key eq 'GENRE') {
								$actions = {
									'go' => {
										'cmd' => ['artists'],
										'params' => {
											'menu' => 'album',
											'menu_all' => 1,
											'genre_id' => $id,
										},
									},
									'play' => {
										'player' => 0,
										'cmd' => ['playlistcontrol'],
										'params' => {
											'cmd' => 'load',
											'genre_id' => $id,
										},
									},
									'add' => {
										'player' => 0,
										'cmd' => ['playlistcontrol'],
										'params' => {
											'cmd' => 'add',
											'genre_id' => $id,
										},
									},
								};
								$request->addResultLoop($loopname, $chunkCount, 'window', { 'titleStyle' => 'genres', text => $val } );
							}
						
							# album -- not multi, but _songData simulates it in menuMode so we can add our action here
							elsif ($key eq 'ALBUM') {
								$actions = {
									'go' => {
										'cmd' => ['tracks'],
										'params' => {
											'menu' => 'songinfo',
											'menu_all' => 1,
											'album_id' => $id,
											'sort' => 'tracknum',
										},
									},
									'play' => {
										'player' => 0,
										'cmd' => ['playlistcontrol'],
										'params' => {
											'cmd' => 'load',
											'album_id' => $id,
										},
									},
									'add' => {
										'player' => 0,
										'cmd' => ['playlistcontrol'],
										'params' => {
											'cmd' => 'add',
											'album_id' => $id,
										},
									},
									'add-hold' => {
										'player' => 0,
										'cmd' => ['playlistcontrol'],
										'params' => {
											'cmd' => 'insert',
											'album_id' => $id,
										},
									},
								};
								# style correctly the title that opens for the action element
								$request->addResultLoop($loopname, $chunkCount, 'window', { 'titleStyle' => 'album', 'icon-id' => $trackId, text => $val } );
							}
							
							#or one of the artist role -- we don't test explicitely !!!
							else {
								
								$actions = {
									'go' => {
										'cmd' => ['albums'],
										'params' => {
											'menu' => 'track',
											'menu_all' => 1,
											'artist_id' => $id,
										},
									},
									'play' => {
										'player' => 0,
										'cmd' => ['playlistcontrol'],
										'params' => {
											'cmd' => 'load',
											'artist_id' => $id,
										},
									},
									'add' => {
										'player' => 0,
										'cmd' => ['playlistcontrol'],
										'params' => {
											'cmd' => 'add',
											'artist_id' => $id,
										},
									},
									'add-hold' => {
										'player' => 0,
										'cmd' => ['playlistcontrol'],
										'params' => {
											'cmd' => 'insert',
											'artist_id' => $id,
										},
									},
								};
								
								# style correctly the window that opens for the action element
								$request->addResultLoop($loopname, $chunkCount, 'window', { 'titleStyle' => 'artists', 'menuStyle' => 'album', text => $val } );
							}
							
							$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
						}
						# special case: artwork, only if it exists
						elsif ($key eq 'COVERART' && $artworkExists) {
								# Bug 7443, check for a track cover before using the album cover
								my $coverId = $track->coverArtExists ? $track->id : $val;
							
								$actions = {
									'do' => {
										'cmd' => ['artwork', $coverId],
									},
								};

								$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
								$request->addResultLoop($loopname, $chunkCount, 'showBigArtwork', 1);

								my $text = Slim::Utils::Strings::string('SHOW_ARTWORK');
								$request->addResultLoop($loopname, $chunkCount, 'text', $text);

								# we're going to skip to the next loop (and increment $chunkCount)
								#  so we don't get the 'key: value' style menu item
								$chunkCount++; $idx++; next; 
								
						}
						else {
							# pretty print some of the stuff...
							# it's done all over the place for the web interface:
							## some of it in the template!
							## some of it in Pages::addSongInfo
							## the rest is using pretty printing methods of track
						
							if ($key eq 'COMPILATION') {
								$val = Slim::Utils::Strings::string('YES');
							}

							elsif ( $key eq 'YEAR' && $val != 0 ) {
								my $actions = {
									go => {
										cmd => ["albums"],
										itemsParams => "params",
										params => { year => $val, menu => "track", menu_all => 1 },
                                          },
									'play' => {
										player => 0,
										itemsParams => 'params',
										cmd => ['playlistcontrol'],
										params => {
											year => $val,
											cmd => 'load',
										},
									},
									'add' => {
										player => 0,
										itemsParams => 'params',
										cmd => ['playlistcontrol'],
										params => {
											year => $val,
											cmd => 'add',
										},
									},
									'add-hold' => {
										player => 0,
										itemsParams => 'params',
										cmd => ['playlistcontrol'],
										params => {
											year => $val,
											cmd => 'insert',
										},
									},
								};
								# style correctly the title that opens for the action element
								$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
								$request->addResultLoop($loopname, $chunkCount, 'window', { 'menuStyle' => 'album' , 'titleStyle' => 'mymusic' } );

							}
							elsif ($key eq 'LENGTH') {
								$val = $track->duration();
							}
							elsif ($key eq 'ALBUMREPLAYGAIN' || $key eq 'REPLAYGAIN') {
								$val = sprintf("%2.2f", $val) . " dB";
							}
							elsif ($key eq 'RATING') {
								$val = $val / 100;
							}
							elsif ($key eq 'FILELENGTH') {
								$val = Slim::Utils::Misc::delimitThousands($val) . " " . Slim::Utils::Strings::string('BYTES');
							}
							elsif ($key eq 'SAMPLERATE') {
								$val = $track->prettySampleRate();
							}
							elsif ($key eq 'SAMPLESIZE') {
								$val = $val . " " . Slim::Utils::Strings::string('BITS');
							}
							elsif ($key eq 'LOCATION') {
								$val = $track->path();
							}
							elsif ( $key eq 'YEAR' && $val eq '0' ||
								$key eq 'COMMENT' && $val eq '0' ||
								$key eq 'SHOW_ARTWORK' || # always suppress coverArtExists
								$key eq 'COVERART' && !$artworkExists) {
								# bug 5241, don't show YEAR or COMMENT if it's 0
								$suppress = 1; 
							} 
							# comments are often long, so we deliver them in a new window as a textarea
							elsif ( $key eq 'COMMENT' && $val ne '0') {
								$request->addResultLoop($loopname, $chunkCount, 'text', Slim::Utils::Strings::string($key));
								$request->addResultLoop($loopname, $chunkCount, 'textArea', $val);

								my $window = { 
									text =>Slim::Utils::Strings::string($key) . ": " . $hashRef->{TITLE},  
									titleStyle => 'mymusic' 
								};
                						$request->addResultLoop($loopname, $chunkCount, 'window', $window);

								my $actions = {
						                # this is a dummy command...doesn't do anything but is required
									go =>   {
                                               					 cmd    => ['playerinformation'],
							                         player => 0,
									},
								};
								$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
								$request->addResultLoop($loopname, $chunkCount, 'style', 'item');

								# we want chunkCount to increment, but not to add the key:val text string below
								$chunkCount++; $idx++; next;
							}
							
							my $style   = $key eq 'YEAR' ? 'item' : 'itemNoAction';
							$request->addResultLoop($loopname, $chunkCount, 'style', $style) unless $suppress;
						}
						$request->addResultLoop($loopname, $chunkCount, 'text', Slim::Utils::Strings::string($key) . ": " . $val) unless $suppress;
					}
					else {
						$request->addResultLoop($loopname, $chunkCount, $key, $val);
					}
					if ($suppress) {
						# now there's one less in the loop
						$count--;
						$totalCount--;
						$idx--;
					}
					else {
						$chunkCount++;					
					}
				}
				$idx++;
 			}

			# Add Favorites as the last item to all chunks (the assumption is that there will be 1 chunk in this response 100% of the time)
			($chunkCount, $totalCount) = _jiveAddToFavorites(lastChunk => 1, start => $start, chunkCount => $chunkCount, listCount => $totalCount, request => $request, loopname => $loopname, favorites => \%favorites);

			# because of suppression of some items, only now can we add the count
			$request->addResult("count", $totalCount);

		}
		}
	}

	$request->setStatusDone();
}


sub syncQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query
	if ($request->isNotQuery([['sync']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	if (Slim::Player::Sync::isSynced($client)) {
	
		my @buddies = Slim::Player::Sync::syncedWith($client);
		my @sync_buddies = map { $_->id() } @buddies;

		$request->addResult('_sync', join(",", @sync_buddies));
	} else {
	
		$request->addResult('_sync', '-');
	}
	
	$request->setStatusDone();
}


sub timeQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['time', 'gototime']])) {
		$request->setStatusBadDispatch();
		return;
	}
	
	# get the parameters
	my $client = $request->client();

	$request->addResult('_time', Slim::Player::Source::songTime($client));
	
	$request->setStatusDone();
}

sub titlesQuery {
	my $request = shift;

	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['titles', 'tracks', 'songs']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# Bug 6889, exclude remote tracks from these queries
	my $where  = { 'me.remote' => { '!=' => 1 } };
	my $attr   = {};

	my $tags   = 'gald';

	# get our parameters
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');
	my $tagsprm       = $request->getParam('tags');
	my $sort          = $request->getParam('sort');
	my $search        = $request->getParam('search');
	my $genreID       = $request->getParam('genre_id');
	my $contributorID = $request->getParam('artist_id');
	my $albumID       = $request->getParam('album_id');
	my $year          = $request->getParam('year');
	my $menuStyle     = $request->getParam('menuStyle') || 'item';

	my %favorites;
	$favorites{'url'} = $request->getParam('favorites_url');
	$favorites{'title'} = $request->getParam('favorites_title');
	
	my $menu          = $request->getParam('menu');
	my $insert        = $request->getParam('menu_all');
	
	# menu/jive mgmt
	my $menuMode = defined $menu;
	my $insertAll = $menuMode && defined $insert;

	if ($request->paramNotOneOfIfDefined($sort, ['title', 'tracknum'])) {
		$request->setStatusBadParams();
		return;
	}

	# did we have override on the defaults?
	# note that this is not equivalent to 
	# $val = $param || $default;
	# since when $default eq '' -> $val eq $param
	$tags = $tagsprm if defined $tagsprm;

	# Normalize any search parameters
	if (specified($search)) {
		$where->{'me.titlesearch'} = {'like' => Slim::Utils::Text::searchStringSplit($search)};
	}

	if (defined $albumID){
		$where->{'me.album'} = $albumID;
	}

	if (defined $year) {
		$where->{'me.year'} = $year;
	}

	# we don't want client playlists (Now playing), transporter sources,
	# directories, or playlists.
	$where->{'me.content_type'} = [ -and => {'!=', 'cpl'},  {'!=', 'src'},  {'!=', 'ssp'}, {'!=', 'dir'} ];

	# Manage joins
	if (defined $genreID) {

		$where->{'genreTracks.genre'} = $genreID;

		push @{$attr->{'join'}}, 'genreTracks';
#		$attr->{'distinct'} = 1;
	}

	if (defined $contributorID) {
	
		# handle the case where we're asked for the VA id => return compilations
		if ($contributorID == Slim::Schema->variousArtistsObject->id) {
			$where->{'album.compilation'} = 1;
			push @{$attr->{'join'}}, 'album';
		}
		else {	
			$where->{'contributorTracks.contributor'} = $contributorID;
			push @{$attr->{'join'}}, 'contributorTracks';
		}
	}

	if ($sort && $sort eq "tracknum") {

		if (!($tags =~ /t/)) {
			$tags = $tags . "t";
		}

		$attr->{'order_by'} =  "me.disc, me.tracknum, concat('0', me.titlesort)";
	}
	else {
		$attr->{'order_by'} =  "me.titlesort";
	}

	my $rs = Slim::Schema->rs('Track')->search($where, $attr)->distinct;

	my $count = $rs->count;

	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to songinfo after albums, so we get menu:track
		# from songinfo we go nowhere...
		my $actioncmd = 'songinfo';
		my $nextMenu = 'nowhere';
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => [$actioncmd],
					'params' => {
						'menu' => $nextMenu,
#						'menu_play' => '1',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
				'add-hold' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'insert',
					},
					'itemsParams' => 'params',
				},
			},
			'window' => {
				'titleStyle' => 'album',
			}
		};
		$request->addResult('base', $base);
		
	}

	if (Slim::Music::Import->stillScanning) {
		$request->addResult("rescan", 1);
	}

	$count += 0;
	my $totalCount = _fixCount($insertAll, \$index, \$quantity, $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	my $loopname = $menuMode?'item_loop':'titles_loop';
	# this is the count of items in this part of the request (e.g., menu 100 200)
	# not to be confused with $count, which is the count of the entire list
	my $chunkCount = 0;
	$request->addResult('offset', $request->getParam('_index')) if $menuMode;

	if ($valid) {
		
		my $format = $prefs->get('titleFormat')->[ $prefs->get('titleFormatWeb') ];

		# first PLAY ALL item
		if ($insertAll) {
			$chunkCount = _playAll(start => $start, end => $end, chunkCount => $chunkCount, request => $request, loopname => $loopname, includeArt => ( $menuStyle eq 'album' ) );
		}


		for my $item ($rs->slice($start, $end)) {
			
			# jive formatting
			if ($menuMode) {
				
				my $id = $item->id();
				$id += 0;
				my $params = {
					'track_id' =>  $id, 
				};
				$request->addResultLoop($loopname, $chunkCount, 'params', $params);
			
			
				# open a window with icon etc...
			

				my $text = $item->title;
				my $album;
				my $albumObj = $item->album();
				
				# Bug 7443, check for a track cover before using the album cover
				my $iconId = $item->coverArtExists ? $id : 0;
				
				if(defined($albumObj)) {
					$album = $albumObj->title();
					$iconId ||= $albumObj->artwork();
				}
				$text = $text . "\n" . (defined($album)?$album:"");
			
				my $artist;
				if(defined(my $artistObj = $item->artist())) {
					$artist = $artistObj->name();
				}
				$text = $text . "\n" . (defined($artist)?$artist:"");
			
				my $window = {
					'text' => $text,
				};

				if ($menuStyle eq 'album') {
					$request->addResultLoop($loopname, $chunkCount, 'style', 'albumitem');
					$request->addResultLoop($loopname, $chunkCount, 'text', $text);
				} else {
					my $oneLineTrackTitle = Slim::Music::TitleFormatter::infoFormat($item, $format, 'TITLE');
					$request->addResultLoop($loopname, $chunkCount, 'text', $oneLineTrackTitle);
				}
			
				if (defined($iconId)) {
					$iconId += 0;
					$window->{'icon-id'} = $iconId;
					if ($menuStyle eq 'album') {
						$request->addResultLoop($loopname, $chunkCount, 'icon-id', $iconId);
					}
				}

				$request->addResultLoop($loopname, $chunkCount, 'window', $window);
			}
			
			# regular formatting
			else {
				_addSong($request, $loopname, $chunkCount, $item, $tags);
			}
			
			$chunkCount++;
			
			# give peace a chance...
			if ($chunkCount % 5) {
				::idleStreams();
			}
		}

		if ($menuMode) {
			# Add Favorites as the last item, if applicable
			my $lastChunk;
			if ( $end == $count - 1 && $chunkCount < $request->getParam('_quantity') ) {
				$lastChunk = 1;
			}
			($chunkCount, $totalCount) = _jiveAddToFavorites(lastChunk => $lastChunk, start => $start, listCount => $totalCount, chunkCount => $chunkCount, request => $request, loopname => $loopname, favorites => \%favorites);
		}
	}
	elsif ($totalCount > 1 && $menuMode) {
		($chunkCount, $totalCount) = _jiveAddToFavorites(lastChunk => 1, start => $start, listCount => $totalCount, chunkCount => $chunkCount, request => $request, loopname => $loopname, favorites => \%favorites);
	}

	if ($totalCount == 0 && $menuMode) {
		# this is an empty resultset
		_jiveNoResults($request);
	} else {
		$request->addResult('count', $totalCount);
	}


	$request->setStatusDone();
}


sub versionQuery {
	my $request = shift;
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['version']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# no params for the version query

	$request->addResult('_version', $::VERSION);
	
	$request->setStatusDone();
}


sub yearsQuery {
	my $request = shift;

	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([['years']])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index         = $request->getParam('_index');
	my $quantity      = $request->getParam('_quantity');	
	my $menu          = $request->getParam('menu');
	my $insert        = $request->getParam('menu_all');
	
	# menu/jive mgmt
	my $menuMode  = defined $menu;
	my $insertAll = $menuMode && defined $insert;
	
	# get them all by default
	my $where = {};
	
	# sort them
	my $attr = {
		'distinct' => 'me.id'
	};

	my $rs = Slim::Schema->resultset('Year')->browse->search($where, $attr);

	my $count = $rs->count;

	# now build the result
	
	if ($menuMode) {

		# decide what is the next step down
		# generally, we go to albums after years, so we get menu:album
		# from the albums we'll go to tracks
		my $actioncmd = $menu . 's';
		my $nextMenu = 'track';
		
		# build the base element
		my $base = {
			'actions' => {
				'go' => {
					'cmd' => [$actioncmd],
					'params' => {
						menu     => $nextMenu,
						menu_all => '1',
					},
					'itemsParams' => 'params',
				},
				'play' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'load',
					},
					'itemsParams' => 'params',
				},
				'add' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'add',
					},
					'itemsParams' => 'params',
				},
				'add-hold' => {
					'player' => 0,
					'cmd' => ['playlistcontrol'],
					'params' => {
						'cmd' => 'insert',
					},
					'itemsParams' => 'params',
				},
			},
			'window' => {
				menuStyle   => 'album',
				titleStyle  => 'years',
			}
		};
		$request->addResult('base', $base);
	}

	if (Slim::Music::Import->stillScanning()) {
		$request->addResult('rescan', 1);
	}

	$count += 0;
	my $totalCount = _fixCount($insertAll, \$index, \$quantity, $count);

	my ($valid, $start, $end) = $request->normalize(scalar($index), scalar($quantity), $count);

	if ($valid) {

		my $loopname = $menuMode?'item_loop':'years_loop';
		my $chunkCount = 0;
		$request->addResult('offset', $request->getParam('_index')) if $menuMode;

		if ($insertAll) {
			$chunkCount = _playAll(start => $start, end => $end, chunkCount => $chunkCount, request => $request, loopname => $loopname);
		}

		for my $eachitem ($rs->slice($start, $end)) {


			my $id = $eachitem->id();
			$id += 0;

			my $url = $eachitem->id() ? 'db:year.id=' . $eachitem->id() : 0;

			if ($menuMode) {
				$request->addResultLoop($loopname, $chunkCount, 'text', $eachitem->name);

				my $params = {
					'year'            => $id,
					# bug 6781: can't add a year to favorites
					'favorites_url'   => $url,
					'favorites_title' => $id,
				};

				$request->addResultLoop($loopname, $chunkCount, 'params', $params);
			}
			else {
				$request->addResultLoop($loopname, $chunkCount, 'year', $id);
			}
			$chunkCount++;
		}
	}

	if ($totalCount == 0 && $menuMode) {
		_jiveNoResults($request);
	} else {
		$request->addResult('count', $totalCount);
	}

	$request->setStatusDone();
}

################################################################################
# Special queries
################################################################################

=head2 dynamicAutoQuery( $request, $query, $funcptr, $data )

 This function is a helper function for any query that needs to poll enabled
 plugins. In particular, this is used to implement the CLI radios query,
 that returns all enabled radios plugins. This function is best understood
 by looking as well in the code used in the plugins.
 
 Each plugins does in initPlugin (edited for clarity):
 
    $funcptr = addDispatch(['radios'], [0, 1, 1, \&cli_radiosQuery]);
 
 For the first plugin, $funcptr will be undef. For all the subsequent ones
 $funcptr will point to the preceding plugin cli_radiosQuery() function.
 
 The cli_radiosQuery function looks like:
 
    sub cli_radiosQuery {
      my $request = shift;
      
      my $data = {
         #...
      };
 
      dynamicAutoQuery($request, 'radios', $funcptr, $data);
    }
 
 The plugin only defines a hash with its own data and calls dynamicAutoQuery.
 
 dynamicAutoQuery will call each plugin function recursively and add the
 data to the request results. It checks $funcptr for undefined to know if
 more plugins are to be called or not.
 
=cut

sub dynamicAutoQuery {
	my $request = shift;                       # the request we're handling
	my $query   = shift || return;             # query name
	my $funcptr = shift;                       # data returned by addDispatch
	my $data    = shift || return;             # data to add to results
	
	$log->info("Begin Function");

	# check this is the correct query.
	if ($request->isNotQuery([[$query]])) {
		$request->setStatusBadDispatch();
		return;
	}

	# get our parameters
	my $index    = $request->getParam('_index');
	my $quantity = $request->getParam('_quantity') || 0;
	my $sort     = $request->getParam('sort');
	my $menu     = $request->getParam('menu');

	my $menuMode = defined $menu;

	# we have multiple times the same resultset, so we need a loop, named
	# after the query name (this is never printed, it's just used to distinguish
	# loops in the same request results.
	my $loop = $menuMode?'item_loop':$query . 's_loop';

	# if the caller asked for results in the query ("radios 0 0" returns 
	# immediately)
	if ($quantity) {

		# add the data to the results
		my $cnt = $request->getResultLoopCount($loop) || 0;
		
		if ( ref $data eq 'HASH' && scalar keys %{$data} ) {
			$data->{weight} = $data->{weight} || 100;
			$request->setResultLoopHash($loop, $cnt, $data);
		}
		
		# more to jump to?
		# note we carefully check $funcptr is not a lemon
		if (defined $funcptr && ref($funcptr) eq 'CODE') {
			
			eval { &{$funcptr}($request) };
	
			# arrange for some useful logging if we fail
			if ($@) {

				logError("While trying to run function coderef: [$@]");
				$request->setStatusBadDispatch();
				$request->dump('Request');
			}
		}
		
		# $funcptr is undefined, we have everybody, now slice & count
		else {
			
			# sort if requested to do so
			if ($sort) {
				$request->sortResultLoop($loop, $sort);
			}
			
			# slice as needed
			my $count = $request->getResultLoopCount($loop);
			$request->sliceResultLoop($loop, $index, $quantity);
			$request->addResult('offset', $request->getParam('_index')) if $menuMode;
			$count += 0;
			$request->setResultFirst('count', $count);
			
			# don't forget to call that to trigger notifications, if any
			$request->setStatusDone();
		}
	}
	else {
		$request->setStatusDone();
	}
}

################################################################################
# Helper functions
################################################################################

sub _addSong {
	my $request   = shift; # request
	my $loop      = shift; # loop
	my $index     = shift; # loop index
	my $pathOrObj = shift; # song path or object
	my $tags      = shift; # tags to use
	my $prefixKey = shift; # prefix key, if any
	my $prefixVal = shift; # prefix value, if any   

	# get the hash with the data	
	my $hashRef = _songData($request, $pathOrObj, $tags);
	
	# add the prefix in the first position, use a fancy feature of
	# Tie::LLHash
	if (defined $prefixKey) {
		(tied %{$hashRef})->Unshift($prefixKey => $prefixVal);
	}
	
	# add it directly to the result loop
	$request->setResultLoopHash($loop, $index, $hashRef);
}

sub _addJivePlaylistControls {

	my ($request, $loop, $count) = @_;
	
	my $client = $request->client;
	
	# clear playlist
	my $text = $client->string('CLEAR_PLAYLIST');
	# add clear playlist and save playlist menu items
	$count++;
	my @clear_playlist = (
		{
			text    => $client->string('CANCEL'),
			actions => {
				go => {
					player => 0,
					cmd    => [ 'jiveblankcommand' ],
				},
			},
			nextWindow => 'playlist',
		},
		{
			text    => $client->string('CLEAR_PLAYLIST'),
			actions => {
				do => {
					player => 0,
					cmd    => ['playlist', 'clear'],
				},
			},
			nextWindow => 'home',
		},
	);

	$request->addResultLoop($loop, $count, 'text', $text);
	$request->addResultLoop($loop, $count, 'icon-id', '/html/images/blank.png');
	$request->addResultLoop($loop, $count, 'offset', 0);
	$request->addResultLoop($loop, $count, 'count', 2);
	$request->addResultLoop($loop, $count, 'item_loop', \@clear_playlist);
	$request->addResultLoop($loop, $count, 'window', { titleStyle => 'playlist' } );

	# save playlist
	my $input = {
		len          => 1,
		allowedChars => $client->string('JIVE_ALLOWEDCHARS_WITHCAPS'),
		help         => {
			text => $client->string('JIVE_SAVEPLAYLIST_HELP'),
		},
	};
	my $actions = {
		do => {
			player => 0,
			cmd    => ['playlist', 'save'],
			params => {
				playlistName => '__INPUT__',
			},
			itemsParams => 'params',
		},
	};
	$count++;

	$text = $client->string('SAVE_PLAYLIST');
	$request->addResultLoop($loop, $count, 'text', $text);
	$request->addResultLoop($loop, $count, 'icon-id', '/html/images/blank.png');
	$request->addResultLoop($loop, $count, 'input', $input);
	$request->addResultLoop($loop, $count, 'actions', $actions);
	$request->addResultLoop($loop, $count, 'window', { titleStyle => 'playlist' } );

}

sub _addJiveSong {
	my $request   = shift; # request
	my $loop      = shift; # loop
	my $count     = shift; # loop index
	my $current   = shift;
	my $track     = shift;
	
	# If we have a remote track, check if a plugin can provide metadata
	my $remoteMeta = {};
	if ( $track->remote ) {
		my $url     = $track->url;
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
		$request->addResultLoop($loop, $count, 'trackType', 'radio');
		if ( $handler && $handler->can('getMetadataFor') ) {
			$remoteMeta = $handler->getMetadataFor( $request->client, $url );
			
			# if we have a plugin-defined title, remove the current_title value
			if ( $current && $remoteMeta->{title} ) {
				$request->addResult( 'current_title' => undef );
			}
			
			# Bug 6943, let plugins override the duration value, radio-type plugins
			# like Pandora need this because they change the duration when the next
			# track begins streaming
			if ( $current && $remoteMeta->{duration} ) {
				$request->addResult( duration => $remoteMeta->{duration} + 0 );
			}
		}
	} else {
		$request->addResultLoop($loop, $count, 'trackType', 'local');
	}
	
	my $text = $remoteMeta->{title} || $track->title;
	my $album;
	my $albumObj = $track->album();
	my $iconId;
	
	# Bug 7443, check for a track cover before using the album cover
	if ( $track->coverArtExists() ) {
		$iconId = $track->id;
	}
	
	if ( defined $albumObj ) {
		$album = $albumObj->title();
		$iconId ||= $albumObj->artwork();
	}
	elsif ( $remoteMeta->{album} ) {
		$album = $remoteMeta->{album};
	}
	

	$text .= ( defined $album ) ? "\n$album" : '';
	
	my $artist;
	if ( defined( my $artistObj = $track->artist() ) ) {
		$artist = $artistObj->name();
	}
	elsif ( $remoteMeta->{artist} ) {
		$artist = $remoteMeta->{artist};
	}
	
	$text .= ( defined $artist ) ? "\n$artist" : '';
	
	if ( defined $iconId ) {
		$iconId += 0;
		$request->addResultLoop($loop, $count, 'icon-id', $iconId);
	}
	elsif ( $remoteMeta->{cover} ) {
		$request->addResultLoop( $loop, $count, 'icon', $remoteMeta->{cover} );
	}
	
	# Special case for Internet Radio streams, if the track is remote, has no duration,
	# has title metadata, and has no album metadata, display the station title as line 1 of the text
	if ( $track->remote && !$track->secs && $remoteMeta->{title} && !$album ) {
		$text = $track->title . "\n" . $text;
	}

	$request->addResultLoop($loop, $count, 'text', $text);

	# Add trackinfo menu action for remote URLs
	if ( $track->remote ) {

		# Protocol Handlers can define their own track info OPML menus
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL( $track->url );
		my $actions;
		# this covers things like Rhapsody, Pandora, etc.
		# trackinfo CLI command is in Slim::Buttons::Trackinfo
		if ( $handler && $handler->can('trackInfoURL') ) {
        		$actions = {
				go => {
					cmd    => [ 'trackinfo', 'items' ],
					params => {
						menu => 'menu',
						url  => $track->url,
					},
				},
			};
		# this covers standard internet streams
	        } else {
        		$actions = {
				go => {
					cmd    => [ 'songinfo' ],
					params => {
						menu => 'menu',
						url  => $track->url,
						context => 'playlist',
						playlist_index => $count,
					},
				},
			};
		}
		$request->addResultLoop( $loop, $count, 'actions', $actions );
	}

	my $id = $track->id();
	$id += 0;
	my $params = {
		'track_id' => $id, 
		'playlist_index' => $count,
	};
	$request->addResultLoop($loop, $count, 'params', $params);
}


sub _jiveNoResults {
	my $request = shift;
	my $search = $request->getParam('search');
	$request->addResult('count', '1');
	$request->addResult('offset', 0);

	if (defined($search)) {
		$request->addResultLoop('item_loop', 0, 'text', Slim::Utils::Strings::string('NO_SEARCH_RESULTS'));
	} else {
		$request->addResultLoop('item_loop', 0, 'text', Slim::Utils::Strings::string('EMPTY'));
	}

	$request->addResultLoop('item_loop', 0, 'style', 'itemNoAction');
	$request->addResultLoop('item_loop', 0, 'action', 'none');
}

sub _jiveAddToFavorites {

	my %args       = @_;
	my $chunkCount = $args{'chunkCount'};
	my $listCount  = $args{'listCount'};
	my $loopname   = $args{'loopname'};
	my $request    = $args{'request'};
	my $favorites  = $args{'favorites'};
	my $start      = $args{'start'};
	my $lastChunk  = $args{'lastChunk'};
	my $includeArt = $args{'includeArt'};


	return ($chunkCount, $listCount) unless $loopname && $favorites;
	
	# Do nothing unless Favorites are enabled
	if ( !Slim::Utils::PluginManager->isEnabled('Slim::Plugin::Favorites::Plugin') ) {
		return ($chunkCount, $listCount);
	}

	# we need %favorites populated or else we don't want this item
	if (!$favorites->{'title'} || !$favorites->{'url'}) {
		return ($chunkCount, $listCount);
	}
	
	# We'll add a Favorites item to this request.
	# We always bump listCount to indicate this request list will contain one more item at the end
	$listCount++;

	# Add the actual favorites item if we're in the last chunk
	if ( $lastChunk ) {
		my $action = 'add';
		my $token = 'JIVE_ADD_TO_FAVORITES';
		# first we check to see if the URL exists in favorites already
		my $client = $request->client();
		my $favIndex = undef;
		if ( blessed($client) ) {
			my $favs = Slim::Utils::Favorites->new($client);
			$favIndex = $favs->findUrl($favorites->{'url'});
			if (defined($favIndex)) {
				$action = 'delete';
				$token = 'JIVE_DELETE_FROM_FAVORITES';
			}
		}

		$request->addResultLoop($loopname, $chunkCount, 'text', Slim::Utils::Strings::string($token));
		my $actions = {
			'go' => {
				player => 0,
				cmd    => [ 'jivefavorites', $action ],
				params => {
						title   => $favorites->{'title'},
						url     => $favorites->{'url'},
				},
			},
		};
		$actions->{'go'}{'params'}{'item_id'} = $favIndex if defined($favIndex);

		$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
		$request->addResultLoop($loopname, $chunkCount, 'window', { 'titleStyle' => 'favorites' });

		if ($includeArt) {
			$request->addResultLoop($loopname, $chunkCount, 'style', 'albumitem');
			$request->addResultLoop($loopname, $chunkCount, 'icon-id', '/html/images/favorites.png');
		} else {
			$request->addResultLoop($loopname, $chunkCount, 'style', 'item');
		}
	
		$chunkCount++;
	}

	return ($chunkCount, $listCount);
}

sub _jiveDeletePlaylist {

	my %args          = @_;
	my $chunkCount    = $args{'chunkCount'};
	my $listCount     = $args{'listCount'};
	my $loopname      = $args{'loopname'};
	my $request       = $args{'request'};
	my $start         = $args{'start'};
	my $end           = $args{'end'};
	my $lastChunk     = $args{'lastChunk'};
	my $playlistURL   = $args{'playlistURL'};
	my $playlistTitle = $args{'playlistTitle'};
	my $playlistID    = $args{'playlistID'};

	return ($chunkCount, $listCount) unless $loopname && $playlistURL;
	return ($chunkCount, $listCount) if $start == 0 && $end == 0;
	
	# We always bump listCount to indicate this request list will contain one more item at the end
	$listCount++;

	# Add the actual favorites item if we're in the last chunk
	if ( $lastChunk ) {
		my $token = 'JIVE_DELETE_PLAYLIST';
		$request->addResultLoop($loopname, $chunkCount, 'text', Slim::Utils::Strings::string($token));
		my $actions = {
			'go' => {
				player => 0,
				cmd    => [ 'jiveplaylists', 'delete' ],
				params => {
						url	        => $playlistURL,
						playlist_id     => $playlistID,
						title           => $playlistTitle,
						menu		=> 'track',
						menu_all	=> 1,
				},
			},
		};

		$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
		$request->addResultLoop($loopname, $chunkCount, 'window', { 'titleStyle' => 'playlist' });
		$request->addResultLoop($loopname, $chunkCount, 'style', 'item');
		$chunkCount++;
	}

	return ($chunkCount, $listCount);
}

sub _jiveGenreAllAlbums {

	my %args       = @_;
	my $chunkCount = $args{'chunkCount'};
	my $listCount  = $args{'listCount'};
	my $loopname   = $args{'loopname'};
	my $request    = $args{'request'};
	my $start      = $args{'start'};
	my $end        = $args{'end'};
	my $lastChunk  = $args{'lastChunk'};
	my $genreID    = $args{'genreID'};
	my $genreString    = $args{'genreString'};
	my $includeArt = $args{'includeArt'};

	return ($chunkCount, $listCount) unless $loopname && $genreID;
	return ($chunkCount, $listCount) if $start == 0 && $end == 0;
	
	# We always bump listCount to indicate this request list will contain one more item at the end
	$listCount++;

	# Add the actual favorites item if we're in the last chunk
	if ( $lastChunk ) {
		my $token = 'ALL_ALBUMS';
		$request->addResultLoop($loopname, $chunkCount, 'text', Slim::Utils::Strings::string($token));
		my $actions = {
			'go' => {
				player => 0,
				cmd    => [ 'albums' ],
				params => {
						genre_id	=> $genreID,
						menu		=> 'track',
						menu_all	=> 1,
				},
			},
		};

		$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
		$request->addResultLoop($loopname, $chunkCount, 'window', { 'titleStyle' => 'genres', text => "$genreString" });

		if ($includeArt) {
			$request->addResultLoop($loopname, $chunkCount, 'style', 'albumitem');
			$request->addResultLoop($loopname, $chunkCount, 'icon-id', '/html/images/playall.png');
		} else {
			$request->addResultLoop($loopname, $chunkCount, 'style', 'item');
		}
	
		$chunkCount++;
	}

	return ($chunkCount, $listCount);
}

sub _songData {
	my $request   = shift; # current request object
	my $pathOrObj = shift; # song path or object
	my $tags      = shift; # tags to use
	my $menuMode  = shift; # if true, we're in Menu mode


	# figure out the track object
	my $track     = Slim::Schema->rs('Track')->objectForUrl($pathOrObj);

	if (!blessed($track) || !$track->can('id')) {

		logError("Called with invalid object or path: $pathOrObj!");
		
		# For some reason, $pathOrObj may be an id... try that before giving up...
		if ($pathOrObj =~ /^\d+$/) {
			$track = Slim::Schema->find('Track', $pathOrObj);
		}

		if (!blessed($track) || !$track->can('id')) {

			logError("Can't make track from: $pathOrObj!");
			return;
		}
	}
	
	# If we have a remote track, check if a plugin can provide metadata
	my $remoteMeta = {};
	if ( $track->remote ) {
		my $url     = $track->url;
		my $handler = Slim::Player::ProtocolHandlers->handlerForURL($url);
		if ( $handler && $handler->can('getMetadataFor') ) {
			$remoteMeta = $handler->getMetadataFor( $request->client, $url );
			
			$remoteMeta->{a} = $remoteMeta->{artist};
			$remoteMeta->{A} = $remoteMeta->{artist};
			$remoteMeta->{l} = $remoteMeta->{album};
			$remoteMeta->{K} = $remoteMeta->{cover};
			$remoteMeta->{d} = $remoteMeta->{duration};
			$remoteMeta->{Y} = $remoteMeta->{replay_gain};
			$remoteMeta->{o} = $remoteMeta->{type};
			$remoteMeta->{r} = $remoteMeta->{bitrate};
			$remoteMeta->{B} = $remoteMeta->{buttons};
			$remoteMeta->{L} = $remoteMeta->{info_link};

			# if we have a plugin-defined title, remove the current_title value
			if ( $remoteMeta->{title} ) {
				$request->addResult( 'current_title' => undef );
			}
			
			# Bug 6943, let plugins override the duration value, radio-type plugins
			# like Pandora need this because they change the duration when the next
			# track begins streaming
			if ( $remoteMeta->{duration} ) {
				# Bug 7643, only do this if there is only one track on the playlist
				if ( Slim::Player::Playlist::count( $request->client ) == 1 ) {
					$request->addResult( duration => $remoteMeta->{duration} + 0 );
				}
			}
		}
	}
	
	# define an ordered hash for our results
	tie (my %returnHash, "Tie::IxHash");

	# in normal mode, we want to use a tag name as key
	# in menu mode, we want to use a string token we can i8n as key
	my $keyIndex = 0;

	# add fields present no matter $tags
	if ($menuMode) {
		$returnHash{'TITLE'} = $remoteMeta->{title} || $track->title;
		
		# use token as key in menuMode
		$keyIndex = 1;
	}
	else {
		$returnHash{'id'}    = $track->id;
		$returnHash{'title'} = $remoteMeta->{title} || $track->title;
	}

	my %tagMap = (
		# Tag    Tag name             Token            Track method         Track field
		#------------------------------------------------------------------------------
		# '.' => ['id',               '',              'id'],               #id
		  'u' => ['url',              'LOCATION',      'url'],              #url
		  'o' => ['type',             'TYPE',          'content_type'],     #content_type
		# '.' => ['title',            'TITLE',         'title'],            #title
		#                                                                   #titlesort 
		#                                                                   #titlesearch 
		  'e' => ['album_id',         '',              'albumid'],          #album 
		  't' => ['tracknum',         'TRACK',         'tracknum'],         #tracknum
		  'n' => ['modificationTime', 'MODTIME',       'modificationTime'], #timestamp
		  'f' => ['filesize',         'FILELENGTH',    'filesize'],         #filesize
		#                                                                   #tag 
		  'i' => ['disc',             'DISC',          'disc'],             #disc
		  'j' => ['coverart',         'SHOW_ARTWORK',              'coverArtExists'],   #cover
		  'x' => ['remote',           '',              'remote'],           #remote 
		#                                                                   #audio 
		#                                                                   #audio_size 
		#                                                                   #audio_offset
		  'y' => ['year',             'YEAR',          'year'],             #year
		  'd' => ['duration',         'LENGTH',        'secs'],             #secs
		#                                                                   #vbr_scale 
		  'r' => ['bitrate',          'BITRATE',       'prettyBitRate'],    #bitrate
		  'T' => ['samplerate',       'SAMPLERATE',    'samplerate'],       #samplerate 
		  'I' => ['samplesize',       'SAMPLESIZE',    'samplesize'],       #samplesize 
		#                                                                   #channels 
		#                                                                   #block_alignment
		#                                                                   #endian 
		  'm' => ['bpm',              'BPM',           'bpm'],              #bpm
		  'v' => ['tagversion',       'TAGVERSION',    'tagversion'],       #tagversion
		# 'z' => ['drm',              '',              'drm'],              #drm
		#                                                                   #musicmagic_mixable
		#                                                                   #musicbrainz_id 
		#                                                                   #playcount 
		#                                                                   #lastplayed 
		#                                                                   #lossless 
		  'w' => ['lyrics',           'LYRICS',        'lyrics'],           #lyrics 
		  'R' => ['rating',           'RATING',        'rating'],           #rating 
		  'Y' => ['replay_gain',      'REPLAYGAIN',    'replay_gain'],      #replay_gain 
		#                                                                   #replay_peak


		# Tag    Tag name              Token              Relationship     Method          Track relationship
		#--------------------------------------------------------------------------------------------------
		  'a' => ['artist',            'ARTIST',          'artist',        'name'],         #->contributors
		  's' => ['artist_id',         '',                'artist',        'id'],           #->contributors
		  'A' => ['<role>',            '<ROLE>',          'contributors',  'name'],         #->contributors[role].name
		  'S' => ['<role>_ids',        '',                'contributors',  'id'],           #->contributors[role].id
#		  'b' => ['band',              'B',               'band'],                          #->contributors
#		  'c' => ['composer',          'C',               'composer'],                      #->contributors
#		  'h' => ['conductor',         'D',               'conductor'],                     #->contributors
                                                                            
		  'l' => ['album',             'ALBUM',           'album',         'title'],        #->album.title
		  'q' => ['disccount',         '',                'album',         'discc'],        #->album.discc
		  'J' => ["artwork_track_id",  'COVERART',                'album',         'artwork'],      #->album.artwork
		  'C' => ['compilation',       'COMPILATION',     'album',         'compilation'],  #->album.compilation
		  'X' => ['album_replay_gain', 'ALBUMREPLAYGAIN', 'album',         'replay_gain'],  #->album.replay_gain
                                                                            
		  'g' => ['genre',             'GENRE',           'genre',         'name'],         #->genre_track->genre.name
		  'p' => ['genre_id',          '',                'genre',         'id'],           #->genre_track->genre.id
		  'G' => ['genres',            'GENRE',           'genres',        'name'],         #->genre_track->genres.name
		  'P' => ['genre_ids',         '',                'genres',        'id'],           #->genre_track->genres.id
                                                                            
		  'k' => ['comment',           'COMMENT',         'comment'],                       #->comment_object
		  'K' => [''],                                                                      # artwork URL, not in db
		  'B' => [''],                                                                      # radio stream special buttons
		  'L' => [''],                                                                      # special trackinfo link for i.e. Pandora
		  'N' => [''],                                                                      # remote stream title

	);
	
	# loop so that stuff is returned in the order given...
	for my $tag (split //, $tags) {
		
		# special case, artwork URL for remote tracks
		if ($tag eq 'K') {
			if ( my $meta = $remoteMeta->{$tag} ) {
				$returnHash{artwork_url} = $meta;
			}
		}

		# special case, button handling for remote tracks
		elsif ($tag eq 'B') {
			if ( my $meta = $remoteMeta->{$tag} ) {
				$returnHash{buttons} = $meta;
			}
		}

		# special case, remote stream name
		elsif ($tag eq 'N' && $track->remote && !$track->secs && $remoteMeta->{title} && !$remoteMeta->{album} ) {
			if ( my $meta = $track->title ) {
				$returnHash{remote_title} = $meta;
			}
		}
		
		# special case, info_link for remote tracks
		elsif ($tag eq 'L') {
			if ( my $meta = $remoteMeta->{$tag} ) {
				$returnHash{info_link} = $meta;
			}
		}

		# special case artists (tag A and S)
		elsif ($tag eq 'A' || $tag eq 'S') {
			if ( my $meta = $remoteMeta->{$tag} ) {
				$returnHash{artist} = $meta;
				next;
			}
			
			if (defined(my $submethod = $tagMap{$tag}->[3])) {
				
				my $postfix = ($tag eq 'S')?"_ids":"";
			
				foreach my $type (Slim::Schema::Contributor::contributorRoles()) {
				
					if ($menuMode) {
						my $key = uc($type);
						my $idx = 0;
						foreach my $contrib ($track->contributorsOfType($type)->all) {
							$returnHash{$key . "::" . $idx++} = [$contrib->id(), $contrib->name()];
						}
					}
					else {
						
						my $key = lc($type) . $postfix;
						my $value = join(', ', map { $_ = $_->$submethod() } $track->contributorsOfType($type)->all);
				
						if (defined $value && $value ne '') {

							# add the tag to the result
							$returnHash{$key} = $value;
						}
					}
				}
			}
		}

		# if we have a method/relationship for the tag
		elsif (defined(my $method = $tagMap{$tag}->[2])) {
			
			if ($method ne '') {

				my $value;
				my $key = $tagMap{$tag}->[$keyIndex];
				
				# Override with remote track metadata if available
				if ( defined $remoteMeta->{$tag} ) {
					$value = $remoteMeta->{$tag};
				}

				# tag with submethod
				elsif (defined(my $submethod = $tagMap{$tag}->[3])) {

					# call submethod
					if (defined(my $related = $track->$method)) {
						
						# array returned/genre
						if ( blessed($related) && $related->isa('Slim::Schema::ResultSet::Genre')) {
							
							if ($menuMode) {
								my $idx = 0;
								foreach my $genre ($related->all) {
									$returnHash{$key . "::" . $idx++} = [$genre->id(), $genre->name()];
								}
							} 
							else {
								$value = join(', ', map { $_ = $_->$submethod() } $related->all);
							}
						}
						# special case album in menuMode
						elsif ($menuMode && $key eq 'ALBUM') {
							# send a dummy key::0 to trigger adding action in songinfo
							# and return an [id, name] array
							$key = $key . "::0";
							$value = [ $track->albumid(), $related->$submethod() ];
						}
						else {
							$value = $related->$submethod();
						}
					}
				}
				
				# simple track method
				else {
					$value = $track->$method();
				}
				
				# correct values
				if (($tag eq 'R' || $tag eq 'x') && $value == 0) {
					$value = undef;
				}
				
				# if we have a value
				if (defined $value && $value ne '') {

					# add the tag to the result
					$returnHash{$key} = $value;
				}
			}
		}
	}

	return \%returnHash;
}

sub _playAll {

	my %args       = @_;
	my $start      = $args{'start'};
	my $end        = $args{'end'};
	my $chunkCount = $args{'chunkCount'};
	my $loopname   = $args{'loopname'};
	my $request    = $args{'request'};
	my $includeArt = $args{'includeArt'};

	# insert first item if needed
	if ($start == 0 && $end == 0) {
		# one item list, so do not add a play all and just return
		return $chunkCount;
	} elsif ($start == 0) {
		# we're going to add a 'play all' and an 'add all'
		# init some vars for each mode for use in the two item loop below
		my %items = ( 	
			'play' => {
					'string'      => Slim::Utils::Strings::string('JIVE_PLAY_ALL'),
					'style'       => 'itemplay',
					'playAction'  => 'playtracks',
					'addAction'   => 'addtracks',
					'playCmd'     => [ 'playlistcontrol' ],
					'addCmd'      => [ 'playlistcontrol' ],
					'addHoldCmd'      => [ 'playlistcontrol' ],
					'params'      => { 
						'play' =>  { 'cmd' => 'load', },
						'add'  =>  { 'cmd' => 'add',  },
						'add-hold'  =>  { 'cmd' => 'insert',  },
					},
			},
			'add' => { 
					'string'     => Slim::Utils::Strings::string('JIVE_ADD_ALL'),
					'style'      => 'itemadd',
					'playAction' => 'addtracks',
					'addAction'  => 'addtracks',
					'playCmd'    => [ 'playlistcontrol' ],
					'addCmd'     => [ 'playlistcontrol' ],
					'addHoldCmd'     => [ 'playlistcontrol' ],
					'params'     => { 
						'play' =>  { 'cmd' => 'add', },
						'add'  =>  { 'cmd' => 'add', },
						'add-hold'  =>  { 'cmd' => 'insert',  },
					},
			},
	);

		# IF WE DECIDE TO ADD AN 'ADD ALL' item, THIS IS THE ONLY LINE THAT NEEDS CHANGING
		#for my $mode ('play', 'add') {
		for my $mode ('play') {

		$request->addResultLoop($loopname, $chunkCount, 'text', $items{$mode}{'string'});
		$request->addResultLoop($loopname, $chunkCount, 'style', $items{$mode}{'style'});

		if ($includeArt) {
			$request->addResultLoop($loopname, $chunkCount, 'style', 'albumitem');
			$request->addResultLoop($loopname, $chunkCount, 'icon-id', '/html/images/playall.png');
		}

		# get all our params
		my $params = $request->getParamsCopy();
		my $searchType = $request->getParam('_searchType');
	
		# remove keys starting with _ (internal or positional) and make copies
		while (my ($key, $val) = each %{$params}) {
			if ($key =~ /^_/ || $key eq 'menu' || $key eq 'menu_all') {
				next;
			}
			# search is a special case of _playAll, which needs to fire off a different cli command
			if ($key eq 'search') {
				# we don't need a cmd: tagged param for these
				delete($items{$mode}{'params'}{'play'}{'cmd'});
				delete($items{$mode}{'params'}{'add'}{'cmd'});
				delete($items{$mode}{'params'}{'add-hold'}{'cmd'});
				my $searchParam;
				for my $button ('add', 'add-hold', 'play') {
					if ($searchType eq 'artists') {
						$searchParam = 'contributor.namesearch=' . $val;
					} elsif ($searchType eq 'albums') {
						$searchParam = 'album.titlesearch=' . $val;
					} else {
						$searchParam = 'track.titlesearch=' . $val;
					}
				}
				$items{$mode}{'playCmd'} = ['playlist', 'loadtracks', $searchParam ];
				$items{$mode}{'addCmd'}  = ['playlist', 'addtracks', $searchParam ];
				$items{$mode}{'addHoldCmd'}  = ['playlist', 'inserttracks', $searchParam ];
				$items{$mode}{'playCmd'} = $items{$mode}{'addCmd'} if $mode eq 'add';
			} else {
				$items{$mode}{'params'}{'add'}{$key}  = $val;
				$items{$mode}{'params'}{'add-hold'}{$key}  = $val;
				$items{$mode}{'params'}{'play'}{$key} = $val;
			}
		}
				
		# override the actions, babe!
		my $actions = {
			'do' => {
				'player' => 0,
				'cmd'    => $items{$mode}{'playCmd'},
				'params' => $items{$mode}{'params'}{'play'},
			},
			'play' => {
				'player' => 0,
				'cmd'    => $items{$mode}{'playCmd'},
				'params' => $items{$mode}{'params'}{'play'},
			},
			'add' => {
				'player' => 0,
				'cmd'    => $items{$mode}{'addCmd'},
				'params' => $items{$mode}{'params'}{'add'},
			},
			'add-hold' => {
				'player' => 0,
				'cmd'    => $items{$mode}{'addCmd'},
				'params' => $items{$mode}{'params'}{'add-hold'},
			},
		};
		$request->addResultLoop($loopname, $chunkCount, 'actions', $actions);
		$chunkCount++;

		}

	}

	return $chunkCount;

}

# this is a silly little sub that allows jive cover art to be rendered in a large window
sub showArtwork {

	$log->info("Begin showArtwork Function");
	my $request = shift;

	# get our parameters
	my $id = $request->getParam('_artworkid');

	$request->addResult('artworkId'  => $id);
	$request->addResult('offset', 0);
	$request->setStatusDone();

}

# Wipe cached data, called after a rescan
sub wipeCaches {
	$cache = {};
}


# fix the count in case we're adding additional items
# (play all, VA etc.) to the resultset
sub _fixCount {
	my $insertItem = shift;
	my $index      = shift;
	my $quantity   = shift;
	my $count      = shift;

	my $totalCount = $count || 0;

	if ($insertItem && $count > 1) {
		$totalCount++;

		# return one less result as we only add the additional item in the first chunk
		if ( !$$index ) {
			$$quantity--;
		}

		# decrease the index in subsequent queries
		else {
			$$index--;
		}
	}

	return $totalCount;
}


=head1 SEE ALSO

L<Slim::Control::Request.pm>

=cut

1;

__END__
