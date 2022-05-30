//
//  LocationPickerViewController.swift
//  LocationPicker
//
//  Created by Almas Sapargali on 7/29/15.
//  Copyright (c) 2015 almassapargali. All rights reserved.
//

import UIKit
import MapKit
import CoreLocation
import AFNetworking

@objc open class LocationPickerViewController: UIViewController {
    struct CurrentLocationListener {
        let once: Bool
        let action: (CLLocation) -> ()
    }
    
    @objc public var completion: ((Location?) -> ())?
    
    // region distance to be used for creation region when user selects place from search results
    @objc public var resultRegionDistance: CLLocationDistance = 600
    
    /// default: true
    @objc public var showCurrentLocationButton = true
    
    /// default: true
    @objc public var showCurrentLocationInitially = true

    /// default: false
    /// Select current location only if `location` property is nil.
    @objc public var selectCurrentLocationInitially = false
    
    /// see `region` property of `MKLocalSearchRequest`
    /// default: false
    @objc public var useCurrentLocationAsHint = false
    
    /// default: false
    @objc public var viewOnlyBehaviorType = false
    
    /// default: "Search by location"
    @objc public var searchBarPlaceholder = NSLocalizedString("Search by location", comment: "")
    
    /// default: "Search History"
    @objc public var searchHistoryLabel = NSLocalizedString("Search History", comment: "")
    
    @objc public var annotationImage: UIImage?
    
    @objc public var cancelButton: UIButton? {
        didSet {
            self.cancelButton?.addTarget(self, action: #selector(self.cancelButtonTapped), for: .touchUpInside)
        }
    }
    
    @objc public var selectButton: UIButton? {
        didSet {
            self.selectButton?.addTarget(self, action: #selector(self.selectButtonTapped), for: .touchUpInside)
        }
    }
    
    @objc public var myLocationButton: UIButton? {
        didSet {
            self.myLocationButton?.addTarget(self, action: #selector(self.currentLocationPressed), for: .touchUpInside)
        }
    }
    
    @objc public var selectButtonOffset: UIOffset = UIOffset(horizontal: 16, vertical: 20)
    @objc public var myLocationButtonOffset: UIOffset = UIOffset(horizontal: 16, vertical: 20)

    @objc lazy public var currentLocationButtonBackground: UIColor = {
        if let navigationBar = self.navigationController?.navigationBar,
            let barTintColor = navigationBar.barTintColor {
                return barTintColor
        } else {
            return .white
        }
    }()
    
    /// default: .Minimal
    @objc public var searchBarStyle: UISearchBar.Style = .minimal

    /// default: .Default
    @objc public var statusBarStyle: UIStatusBarStyle = .default
    
    @objc public var mapType: MKMapType = .hybrid {
        didSet {
            if self.isViewLoaded {
                self.mapView.mapType = mapType
            }
        }
    }
    
    @objc public var location: Location? {
        didSet {
            if self.isViewLoaded {
                self.searchBar.text = location.flatMap({ $0.title }) ?? ""
                self.selectButton?.isEnabled = self.location != nil
                
                self.updateAnnotation()
            }
        }
    }
    
    static let SearchTermKey = "SearchTermKey"
    
    let historyManager = SearchHistoryManager()
    let locationManager = CLLocationManager()
    let geocoder = CLGeocoder()
    var localSearch: MKLocalSearch?
    var searchTimer: Timer?
    
    var currentLocationListeners: [CurrentLocationListener] = []
    
    var mapView: MKMapView!
    
    lazy var results: LocationSearchResultsViewController = {
        let results = LocationSearchResultsViewController()
        results.onSelectLocation = { [weak self] in self?.selectedLocation($0) }
        results.searchHistoryLabel = self.searchHistoryLabel
        return results
    }()
    
    lazy var searchController: UISearchController = {
        let search = UISearchController(searchResultsController: self.results)
        search.searchResultsUpdater = self
        search.hidesNavigationBarDuringPresentation = false
        return search
    }()
    
    lazy var searchBar: UISearchBar = {
        let searchBar = self.searchController.searchBar
        searchBar.searchBarStyle = self.searchBarStyle
        searchBar.placeholder = self.searchBarPlaceholder
        return searchBar
    }()

    @objc func selectButtonTapped() {
        self.completion?(self.location)
        
        if let navigation = self.navigationController, navigation.viewControllers.count > 1 {
            navigation.popViewController(animated: true)
        } else {
            self.presentingViewController?.dismiss(animated: true, completion: nil)
        }
    }

    @objc func cancelButtonTapped() {
        if let navigation = self.navigationController, navigation.viewControllers.count > 1 {
            navigation.popViewController(animated: true)
        } else {
            self.presentingViewController?.dismiss(animated: true, completion: nil)
        }
    }

    deinit {
        self.searchTimer?.invalidate()
        self.localSearch?.cancel()
        self.geocoder.cancelGeocode()
        // http://stackoverflow.com/questions/32675001/uisearchcontroller-warning-attempting-to-load-the-view-of-a-view-controller/
        let _ = searchController.view
    }
    
    open override func loadView() {
        self.mapView = MKMapView(frame: UIScreen.main.bounds)
        self.mapView.mapType = self.mapType
        self.view = self.mapView
        
        if self.showCurrentLocationButton, let locationButton = self.myLocationButton {
            self.view.addSubview(locationButton)
        }
        
        if !self.viewOnlyBehaviorType, let selectButton = self.selectButton {
            self.view.addSubview(selectButton)
        }
    }
    
    open override func viewDidLoad() {
        super.viewDidLoad()

        self.definesPresentationContext = true
        
        self.locationManager.delegate = self
        self.mapView.delegate = self
        self.searchBar.delegate = self
        
        self.mapView.userTrackingMode = .none
        self.mapView.showsUserLocation = self.showCurrentLocationInitially || self.showCurrentLocationButton
        
        if let cancelButton = self.cancelButton {
            let fixedSpace = UIBarButtonItem(barButtonSystemItem: .fixedSpace, target: nil, action: nil)
            fixedSpace.width = 10
            
            self.navigationItem.leftBarButtonItems = [UIBarButtonItem(customView: cancelButton), fixedSpace]
        }
        
        if self.viewOnlyBehaviorType {
            self.title = self.location?.title
        } else {
            self.navigationItem.titleView = self.searchBar
            
            let locationSelectGesture = UILongPressGestureRecognizer(target: self, action: #selector(addLocation(_:)))
            locationSelectGesture.delegate = self
            self.mapView.addGestureRecognizer(locationSelectGesture)
        }
        
        if self.useCurrentLocationAsHint {
            self.getCurrentLocation()
        }
        
        self.selectButton?.isEnabled = self.location != nil
    }

    open override var preferredStatusBarStyle : UIStatusBarStyle {
        return self.statusBarStyle
    }
    
    var presentedInitialLocation = false
    
    open override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        if let button = self.myLocationButton, button.superview != nil {
            button.frame.origin = CGPoint(x: self.myLocationButtonOffset.horizontal,
                                          y: self.view.frame.height - button.frame.height - self.view.safeAreaInsets.bottom - self.myLocationButtonOffset.vertical)
        }
        
        if let button = self.selectButton, button.superview != nil {
            button.frame.origin = CGPoint(x: self.view.frame.width - button.frame.width - self.selectButtonOffset.horizontal,
                                          y: self.view.frame.height - button.frame.height - self.view.safeAreaInsets.bottom - self.selectButtonOffset.vertical)
        }
        
        // setting initial location here since viewWillAppear is too early, and viewDidAppear is too late
        if !self.presentedInitialLocation {
            self.setInitialLocation()
            self.presentedInitialLocation = true
        }
    }
    
    func setInitialLocation() {
        guard AFNetworkReachabilityManager.shared().isReachable else {
            let title = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as! String
            let alert = UIAlertController(title: title, message: NSLocalizedString("No internet connection", comment: ""), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: { _ in }))
            self.present(alert, animated: true)
            
            return
        }

        if let location = self.location {
            // present initial location if any
            self.location = location
            self.showCoordinates(location.coordinate, animated: false)
            
            return
        } else if showCurrentLocationInitially || selectCurrentLocationInitially {
            if selectCurrentLocationInitially {
                let listener = CurrentLocationListener(once: true) { [weak self] location in
                    if self?.location == nil { // user hasn't selected location still
                        self?.selectLocation(location: location)
                    }
                }
                
                self.currentLocationListeners.append(listener)
            }
            
            self.showCurrentLocation(false)
        }
    }
    
    func getCurrentLocation() {
        self.locationManager.requestWhenInUseAuthorization()
        self.locationManager.startUpdatingLocation()
    }
    
    @objc func currentLocationPressed() {
        self.showCurrentLocation()
    }
    
    func showCurrentLocation(_ animated: Bool = true) {
        let listener = CurrentLocationListener(once: true) { [weak self] location in
            self?.showCoordinates(location.coordinate, animated: animated)
        }
        
        self.currentLocationListeners.append(listener)
        self.getCurrentLocation()
    }
    
    func updateAnnotation() {
        self.mapView.removeAnnotations(mapView.annotations)
        
        if let location = self.location {
            self.mapView.addAnnotation(location)
            self.mapView.selectAnnotation(location, animated: true)
        }
    }
    
    func showCoordinates(_ coordinate: CLLocationCoordinate2D, animated: Bool = true) {
        let region = MKCoordinateRegion(center: coordinate, latitudinalMeters: resultRegionDistance, longitudinalMeters: resultRegionDistance)
        self.mapView.setRegion(region, animated: animated)
    }

    @objc open func selectLocation(location: CLLocation) {
        // add point annotation to map
        let annotation = MKPointAnnotation()
        annotation.coordinate = location.coordinate
        
        self.mapView.addAnnotation(annotation)

        self.geocoder.cancelGeocode()
        
        guard AFNetworkReachabilityManager.shared().isReachable else {
            let alert = UIAlertController(title: nil, message: NSLocalizedString("No internet connection", comment: ""), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: { _ in }))
            self.present(alert, animated: true)
            
            return
        }
        
        self.geocoder.reverseGeocodeLocation(location) { response, error in
            if let error = error as NSError?, error.code != 10 { // ignore cancelGeocode errors
                // show error and remove annotation
                let alert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: { _ in }))
                self.present(alert, animated: true) {
                    self.mapView.removeAnnotation(annotation)
                }
            } else if let placemark = response?.first {
                // get POI name from placemark if any
                let name = placemark.areasOfInterest?.first

                // pass user selected location too
                self.location = Location(name: name, location: location, placemark: placemark)
            }
        }
    }
}

extension LocationPickerViewController: CLLocationManagerDelegate {
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        currentLocationListeners.forEach { $0.action(location) }
        currentLocationListeners = currentLocationListeners.filter { !$0.once }
        manager.stopUpdatingLocation()
    }
}

// MARK: Searching

extension LocationPickerViewController: UISearchResultsUpdating {
    public func updateSearchResults(for searchController: UISearchController) {
        guard let term = searchController.searchBar.text else { return }
        
        searchTimer?.invalidate()

        let searchTerm = term.trimmingCharacters(in: CharacterSet.whitespaces)
        
        if searchTerm.isEmpty {
            results.locations = historyManager.history()
            results.isShowingHistory = true
            results.tableView.reloadData()
        } else {
            // clear old results
            showItemsForSearchResult(nil)
            
            searchTimer = Timer.scheduledTimer(timeInterval: 0.2,
                target: self, selector: #selector(LocationPickerViewController.searchFromTimer(_:)),
                userInfo: [LocationPickerViewController.SearchTermKey: searchTerm],
                repeats: false)
        }
    }
    
    @objc func searchFromTimer(_ timer: Timer) {
        guard let userInfo = timer.userInfo as? [String: AnyObject],
            let term = userInfo[LocationPickerViewController.SearchTermKey] as? String
            else { return }
        
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = term
        
        if let location = locationManager.location, useCurrentLocationAsHint {
            request.region = MKCoordinateRegion(center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 2, longitudeDelta: 2))
        }
        
        localSearch?.cancel()
        localSearch = MKLocalSearch(request: request)
        localSearch!.start { response, _ in
            self.showItemsForSearchResult(response)
        }
    }
    
    func showItemsForSearchResult(_ searchResult: MKLocalSearch.Response?) {
        results.locations = searchResult?.mapItems.map { Location(name: $0.name, placemark: $0.placemark) } ?? []
        results.isShowingHistory = false
        results.tableView.reloadData()
    }
    
    func selectedLocation(_ location: Location) {
        // dismiss search results
        self.dismiss(animated: true) {
            // set location, this also adds annotation
            self.location = location
            self.showCoordinates(location.coordinate)
            
            self.historyManager.addToHistory(location)
        }
    }
}

// MARK: Selecting location with gesture

extension LocationPickerViewController {
    @objc func addLocation(_ gestureRecognizer: UIGestureRecognizer) {
        if gestureRecognizer.state == .began {
            let point = gestureRecognizer.location(in: self.mapView)
            let coordinates = self.mapView.convert(point, toCoordinateFrom: self.mapView)
            let location = CLLocation(latitude: coordinates.latitude, longitude: coordinates.longitude)
            
            // clean location, cleans out old annotation too
            self.location = nil
            self.selectLocation(location: location)
        }
    }
}

// MARK: MKMapViewDelegate

extension LocationPickerViewController: MKMapViewDelegate {
    public func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        if annotation is MKUserLocation {
            return nil
        }
        
        let pin = MKPinAnnotationView(annotation: annotation, reuseIdentifier: "annotation")
        if let image = self.annotationImage {
            pin.image = image
            pin.centerOffset = CGPoint(x: 0, y: -20)
            pin.calloutOffset = CGPoint(x: 0, y: 3)
        } else {
            pin.pinColor = .green
        }
        
        // drop only on long press gesture
        let fromLongPress = annotation is MKPointAnnotation
        pin.animatesDrop = fromLongPress

        pin.canShowCallout = !fromLongPress
        
        return pin
    }
    
    public func mapView(_ mapView: MKMapView, annotationView view: MKAnnotationView, calloutAccessoryControlTapped control: UIControl) {
        self.completion?(location)
        
        if let navigation = self.navigationController, navigation.viewControllers.count > 1 {
            navigation.popViewController(animated: true)
        } else {
            self.presentingViewController?.dismiss(animated: true, completion: nil)
        }
    }
    
    public func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
        let pins = mapView.annotations.filter { $0 is MKPinAnnotationView }
        assert(pins.count <= 1, "Only 1 pin annotation should be on map at a time")

        if let userPin = views.first(where: { $0.annotation is MKUserLocation }) {
            userPin.canShowCallout = false
        }
    }
}

extension LocationPickerViewController: UIGestureRecognizerDelegate {
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
}

// MARK: UISearchBarDelegate

extension LocationPickerViewController: UISearchBarDelegate {
    public func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        // dirty hack to show history when there is no text in search bar
        // to be replaced later (hopefully)
        if let text = searchBar.text, text.isEmpty {
            searchBar.text = " "
        }
    }
    
    public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        // remove location if user presses clear or removes text
        if searchText.isEmpty {
            location = nil
            searchBar.text = " "
        }
    }
}
